import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';
import 'package:tp_agent/src/auth/cbor.dart';
import 'package:tp_agent/src/auth/encoding.dart';
import 'package:tp_agent/src/auth/webauthn.dart';

Uint8List hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

Uint8List bigBytes(BigInt v, int len) {
  final out = Uint8List(len);
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xFF)).toInt();
    v >>= 8;
  }
  return out;
}

Uint8List derInt(BigInt v) {
  var b = bigBytes(v, 32);
  var i = 0;
  while (i < b.length - 1 && b[i] == 0) {
    i++;
  }
  b = b.sublist(i);
  if (b[0] & 0x80 != 0) b = Uint8List.fromList([0, ...b]);
  return Uint8List.fromList([0x02, b.length, ...b]);
}

Uint8List der(BigInt r, BigInt s) {
  final body = [...derInt(r), ...derInt(s)];
  return Uint8List.fromList([0x30, body.length, ...body]);
}

/// A software authenticator holding one P-256 key.
final class FakeAuthenticator {
  FakeAuthenticator() {
    final rnd = FortunaRandom()
      ..seed(
        KeyParameter(
          Uint8List.fromList(
            List.generate(32, (i) => Random.secure().nextInt(256)),
          ),
        ),
      );
    final gen = ECKeyGenerator()
      ..init(
        ParametersWithRandom(
          ECKeyGeneratorParameters(ECCurve_secp256r1()),
          rnd,
        ),
      );
    final pair = gen.generateKeyPair();
    priv = pair.privateKey;
    pub = pair.publicKey;
    random = rnd;
  }

  late final ECPrivateKey priv;
  late final ECPublicKey pub;
  late final SecureRandom random;
  final Uint8List credId = Uint8List.fromList(List.generate(32, (i) => i));
  int counter = 0;

  Uint8List get x => bigBytes(pub.Q!.x!.toBigInteger()!, 32);
  Uint8List get y => bigBytes(pub.Q!.y!.toBigInteger()!, 32);

  Uint8List clientData(String type, Uint8List challenge, String origin) =>
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'type': type,
            'challenge': b64Url(challenge),
            'origin': origin,
            'crossOrigin': false,
          }),
        ),
      );

  Uint8List authData(String rpId, {int flags = 0x05, bool attested = false}) {
    final b = BytesBuilder()
      ..add(sha256.convert(utf8.encode(rpId)).bytes)
      ..addByte(flags | (attested ? 0x40 : 0));
    final c = ByteData(4)..setUint32(0, counter);
    b.add(c.buffer.asUint8List());
    if (attested) {
      b
        ..add(Uint8List(16))
        ..addByte(credId.length >> 8)
        ..addByte(credId.length & 0xFF)
        ..add(credId)
        ..add(cborEncode({1: 2, 3: -7, -1: 1, -2: x, -3: y}));
    }
    return b.takeBytes();
  }

  Uint8List sign(Uint8List message) {
    final signer = ECDSASigner(SHA256Digest())
      ..init(true, ParametersWithRandom(PrivateKeyParameter(priv), random));
    final sig = signer.generateSignature(message) as ECSignature;
    return der(sig.r, sig.s);
  }
}

void main() {
  const rp = RelyingParty(
    id: 'tp.example.com',
    origin: 'https://tp.example.com',
  );
  const verifier = WebAuthnVerifier(rp);
  final challenge = Uint8List.fromList(List.generate(32, (i) => 255 - i));

  test('RFC 6979 A.2.5 P-256/SHA-256 "sample" signature verifies', () {
    final x = hex(
      '60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6',
    );
    final y = hex(
      '7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299',
    );
    final r = BigInt.parse(
      'EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716',
      radix: 16,
    );
    final s = BigInt.parse(
      'F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8',
      radix: 16,
    );
    final msg = Uint8List.fromList(utf8.encode('sample'));
    expect(verifyEs256(x, y, msg, der(r, s)), isTrue);
    expect(
      verifyEs256(x, y, Uint8List.fromList(utf8.encode('samplf')), der(r, s)),
      isFalse,
    );
    expect(verifyEs256(x, y, msg, der(r, s + BigInt.one)), isFalse);
  });

  group('ceremonies', () {
    late FakeAuthenticator auth;
    setUp(() => auth = FakeAuthenticator());

    StoredCredential register() => verifier.verifyRegistration(
      clientDataJson: auth.clientData('webauthn.create', challenge, rp.origin),
      attestationObject: cborEncode({
        'fmt': 'none',
        'attStmt': <Object?, Object?>{},
        'authData': auth.authData(rp.id, attested: true),
      }),
      expectedChallenge: challenge,
      name: 'phone',
    );

    test(
      'registration stores the key; assertion verifies and bumps counter',
      () {
        final cred = register();
        expect(cred.id, auth.credId);
        expect(cred.x, auth.x);
        final restored = StoredCredential.fromJson(
          jsonDecode(jsonEncode(cred.toJson())) as Map<String, Object?>,
        );

        auth.counter = 5;
        final ad = auth.authData(rp.id);
        final cd = auth.clientData('webauthn.get', challenge, rp.origin);
        final sig = auth.sign(
          Uint8List.fromList([...ad, ...sha256.convert(cd).bytes]),
        );
        verifier.verifyAssertion(
          credential: restored,
          clientDataJson: cd,
          authenticatorData: ad,
          signature: sig,
          expectedChallenge: challenge,
        );
        expect(restored.signCount, 5);
        expect(restored.lastUsed, isNotNull);

        // Same counter again looks like a cloned authenticator.
        final sig2 = auth.sign(
          Uint8List.fromList([...ad, ...sha256.convert(cd).bytes]),
        );
        expect(
          () => verifier.verifyAssertion(
            credential: restored,
            clientDataJson: cd,
            authenticatorData: ad,
            signature: sig2,
            expectedChallenge: challenge,
          ),
          throwsA(
            isA<WebAuthnException>().having(
              (e) => e.message,
              'msg',
              contains('counter'),
            ),
          ),
        );
      },
    );

    test('authenticators that keep the counter at zero are accepted', () {
      final cred = register();
      for (var i = 0; i < 2; i++) {
        final ad = auth.authData(rp.id);
        final cd = auth.clientData('webauthn.get', challenge, rp.origin);
        verifier.verifyAssertion(
          credential: cred,
          clientDataJson: cd,
          authenticatorData: ad,
          signature: auth.sign(
            Uint8List.fromList([...ad, ...sha256.convert(cd).bytes]),
          ),
          expectedChallenge: challenge,
        );
      }
    });

    void expectReject(void Function() f, String fragment) => expect(
      f,
      throwsA(
        isA<WebAuthnException>().having(
          (e) => e.message,
          'msg',
          contains(fragment),
        ),
      ),
    );

    test('assertion rejections', () {
      final cred = register();
      auth.counter = 1;
      Uint8List sigFor(Uint8List ad, Uint8List cd) =>
          auth.sign(Uint8List.fromList([...ad, ...sha256.convert(cd).bytes]));
      void attempt({
        String origin = 'https://tp.example.com',
        String type = 'webauthn.get',
        Uint8List? ch,
        String rpId = 'tp.example.com',
        int flags = 0x05,
        bool tamper = false,
      }) {
        final ad = auth.authData(rpId, flags: flags);
        final cd = auth.clientData(type, ch ?? challenge, origin);
        final sig = sigFor(ad, cd);
        if (tamper) ad[ad.length - 1] ^= 1;
        verifier.verifyAssertion(
          credential: cred,
          clientDataJson: cd,
          authenticatorData: ad,
          signature: sig,
          expectedChallenge: challenge,
        );
      }

      expectReject(() => attempt(origin: 'https://evil.example'), 'origin');
      expectReject(() => attempt(type: 'webauthn.create'), 'type');
      expectReject(() => attempt(ch: Uint8List(32)), 'challenge');
      expectReject(() => attempt(rpId: 'evil.example'), 'rpId');
      expectReject(() => attempt(flags: 0x01), 'verified');
      expectReject(() => attempt(flags: 0x04), 'present');
      expectReject(() => attempt(tamper: true), 'signature');
    });

    test('registration rejections', () {
      Object attempt({
        Map<Object?, Object?>? key,
        String origin = 'https://tp.example.com',
        bool attested = true,
      }) {
        final ad = auth.authData(rp.id, attested: attested);
        if (key != null) {
          final head = ad.sublist(
            0,
            ad.length -
                cborEncode({1: 2, 3: -7, -1: 1, -2: auth.x, -3: auth.y}).length,
          );
          return verifier.verifyRegistration(
            clientDataJson: auth.clientData(
              'webauthn.create',
              challenge,
              origin,
            ),
            attestationObject: cborEncode({
              'fmt': 'none',
              'attStmt': <Object?, Object?>{},
              'authData': Uint8List.fromList([...head, ...cborEncode(key)]),
            }),
            expectedChallenge: challenge,
            name: 'x',
          );
        }
        return verifier.verifyRegistration(
          clientDataJson: auth.clientData('webauthn.create', challenge, origin),
          attestationObject: cborEncode({
            'fmt': 'none',
            'attStmt': <Object?, Object?>{},
            'authData': ad,
          }),
          expectedChallenge: challenge,
          name: 'x',
        );
      }

      expectReject(() => attempt(origin: 'http://tp.example.com'), 'origin');
      expectReject(() => attempt(attested: false), 'no attested credential');
      expectReject(
        () => attempt(key: {1: 2, 3: -257, -1: 1, -2: auth.x, -3: auth.y}),
        'ES256',
      );
      expectReject(
        () => attempt(
          key: {1: 2, 3: -7, -1: 1, -2: Uint8List(32), -3: Uint8List(32)},
        ),
        'curve',
      );
      expect(
        () => verifier.verifyRegistration(
          clientDataJson: auth.clientData(
            'webauthn.create',
            challenge,
            rp.origin,
          ),
          attestationObject: Uint8List.fromList([0x9f]),
          expectedChallenge: challenge,
          name: 'x',
        ),
        throwsA(isA<WebAuthnException>()),
      );
    });
  });

  group('cbor', () {
    test('round trip and strictness', () {
      final value = {
        'a': 1,
        2: -300,
        'b': Uint8List.fromList([1, 2]),
        'c': ['x', true, null, false],
        -1: 70000,
      };
      final decoded =
          CborDecoder.decodeAll(cborEncode(value)) as Map<Object?, Object?>;
      expect(decoded['a'], 1);
      expect(decoded[2], -300);
      expect(decoded['b'], [1, 2]);
      expect(decoded['c'], ['x', true, null, false]);
      expect(decoded[-1], 70000);

      expect(
        () => CborDecoder.decodeAll(Uint8List.fromList([0x9f, 0xff])),
        throwsA(isA<CborException>()),
        reason: 'indefinite',
      );
      expect(
        () => CborDecoder.decodeAll(Uint8List.fromList([0xc0, 0x00])),
        throwsA(isA<CborException>()),
        reason: 'tag',
      );
      expect(
        () => CborDecoder.decodeAll(Uint8List.fromList([0xf9, 0, 0])),
        throwsA(isA<CborException>()),
        reason: 'float',
      );
      expect(
        () => CborDecoder.decodeAll(Uint8List.fromList([0xa2, 1, 1, 1, 2])),
        throwsA(isA<CborException>()),
        reason: 'duplicate key',
      );
      expect(
        () => CborDecoder.decodeAll(
          Uint8List.fromList([0x5a, 0xff, 0xff, 0xff, 0xff]),
        ),
        throwsA(isA<CborException>()),
        reason: 'length beyond input',
      );
      expect(
        () => CborDecoder.decodeAll(Uint8List.fromList([0x01, 0x02])),
        throwsA(isA<CborException>()),
        reason: 'trailing',
      );
      final deep = Uint8List.fromList([...List.filled(40, 0x81), 0x00]);
      expect(
        () => CborDecoder.decodeAll(deep),
        throwsA(isA<CborException>()),
        reason: 'depth',
      );
    });

    test('DER parser rejects malformed input', () {
      expect(
        () => parseDerSignature(Uint8List.fromList([0x30, 0x02, 0x02, 0x00])),
        throwsFormatException,
      );
      expect(
        () => parseDerSignature(Uint8List.fromList([0x31, 0x00])),
        throwsFormatException,
      );
    });
  });
}
