import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tp_agent/src/auth/backup_codes.dart';
import 'package:tp_agent/src/auth/encoding.dart';
import 'package:tp_agent/src/auth/password.dart';
import 'package:tp_agent/src/auth/totp.dart';

Uint8List hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

void main() {
  group('argon2id', () {
    test('RFC 9106 section 5.3 test vector', () {
      final tag = argon2id(
        List.filled(32, 0x01),
        List.filled(16, 0x02),
        secret: List.filled(8, 0x03),
        associatedData: List.filled(12, 0x04),
        cost: const Argon2Cost(memoryKiB: 32, iterations: 3, lanes: 4),
      );
      expect(
        tag,
        hex('0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659'),
      );
    });

    test('PHC round trip, verify and reject', () {
      final phc = hashPassword('correct horse battery', cost: Argon2Cost.test);
      expect(phc, startsWith(r'$argon2id$v=19$m=64,t=1,p=1$'));
      expect(PhcHash.parse(phc).toString(), phc);
      expect(verifyPassword('correct horse battery', phc), isTrue);
      expect(verifyPassword('correct horse batterz', phc), isFalse);
      expect(verifyPassword('x', 'garbage'), isFalse);
      expect(
        verifyPassword('x', r'$argon2id$v=19$m=99999999,t=1,p=1$AAAA$AAAA'),
        isFalse,
        reason: 'cost cap',
      );
    });

    test('async variants run off the event loop', () async {
      final phc = await hashPasswordAsync(
        'pw-for-isolate-test',
        cost: Argon2Cost.test,
      );
      expect(await verifyPasswordAsync('pw-for-isolate-test', phc), isTrue);
    });
  });

  group('password policy', () {
    test('length and common list', () {
      expect(checkPasswordStrength('short'), PasswordProblem.tooShort);
      expect(checkPasswordStrength('contortionist'), PasswordProblem.common);
      expect(
        checkPasswordStrength('Contortionist'),
        PasswordProblem.common,
        reason: 'case-insensitive',
      );
      expect(checkPasswordStrength('ship-to-shore-2026!'), isNull);
    });

    test('generated passwords are strong and well-formed', () {
      final p = generatePassword();
      expect(
        p,
        matches(RegExp(r'^([A-HJKMNP-Z2-9]{5}-){3}[A-HJKMNP-Z2-9]{5}$')),
      );
      expect(checkPasswordStrength(p), isNull);
      expect(generatePassword(), isNot(p));
    });
  });

  group('TOTP', () {
    // RFC 6238 Appendix B, SHA-1, 8 digits.
    final rfc = Totp(
      Uint8List.fromList(utf8.encode('12345678901234567890')),
      digits: 8,
    );
    final vectors = {
      59: '94287082',
      1111111109: '07081804',
      1111111111: '14050471',
      1234567890: '89005924',
      2000000000: '69279037',
      20000000000: '65353130',
    };
    vectors.forEach((seconds, code) {
      test('RFC 6238 T=$seconds', () {
        expect(
          rfc.codeAt(
            DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
          ),
          code,
        );
      });
    });

    test('window, replay guard and junk', () {
      final t = Totp.generate();
      final now = DateTime.utc(2026, 11, 18, 12);
      final step = t.stepAt(now);
      expect(t.verify(t.codeForStep(step), now), step);
      expect(t.verify(t.codeForStep(step - 1), now), step - 1);
      expect(t.verify(t.codeForStep(step + 1), now), step + 1);
      expect(t.verify(t.codeForStep(step - 2), now), isNull);
      expect(
        t.verify(t.codeForStep(step), now, lastUsedStep: step),
        isNull,
        reason: 'replay',
      );
      expect(t.verify('12a456', now), isNull);
      expect(t.verify('', now), isNull);
    });

    test('base32 round trip and otpauth uri', () {
      final t = Totp.generate();
      expect(Totp.fromBase32(t.base32Secret).secret, t.secret);
      expect(base32Decode('gezd gnbv-gy3t'), base32Decode('GEZDGNBVGY3T'));
      final uri = Uri.parse(t.uri(account: 'tp.example.com'));
      expect(uri.scheme, 'otpauth');
      expect(uri.host, 'totp');
      expect(uri.queryParameters['secret'], t.base32Secret);
      expect(
        Uri.decodeComponent(uri.path),
        '/Terminal Prompter:tp.example.com',
      );
    });
  });

  group('backup codes', () {
    test('ten unique codes, each works once, normalisation', () {
      final g = BackupCodeSet.generate(cost: Argon2Cost.test);
      expect(g.codes, hasLength(10));
      expect(g.codes.toSet(), hasLength(10));
      for (final c in g.codes) {
        expect(c, matches(RegExp(r'^[A-HJKMNP-Z2-9]{5}-[A-HJKMNP-Z2-9]{5}$')));
      }
      final set = BackupCodeSet.fromJson(
        jsonDecode(jsonEncode(g.stored.toJson())) as Map<String, Object?>,
      );
      final index = set.match(g.codes[3].toLowerCase().replaceAll('-', ' '));
      expect(index, 3);
      set.consume(index!);
      expect(set.remaining, 9);
      expect(set.match(g.codes[3]), isNull, reason: 'used once');
      expect(set.match('AAAAA-AAAAA'), isNull);
      expect(set.match('short'), isNull);
    });
  });

  test('constant-time compare', () {
    expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
    expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
    expect(constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
  });
}
