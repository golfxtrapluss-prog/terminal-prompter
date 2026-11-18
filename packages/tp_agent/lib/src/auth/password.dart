import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'common_passwords.g.dart';
import 'encoding.dart';

/// argon2id cost parameters.
final class Argon2Cost {
  const Argon2Cost({
    required this.memoryKiB,
    required this.iterations,
    required this.lanes,
  });

  /// docs/05: m = 64 MiB, t = 3, p = 2 (about 1.2 s per hash in the AOT
  /// binary on a 2014 laptop, run off the event loop).
  static const Argon2Cost password = Argon2Cost(
    memoryKiB: 65536,
    iterations: 3,
    lanes: 2,
  );

  /// Backup codes have ~50 bits of entropy each and are checked as a set;
  /// OWASP's minimum argon2id setting is enough (about 0.25 s).
  static const Argon2Cost backupCode = Argon2Cost(
    memoryKiB: 19456,
    iterations: 2,
    lanes: 1,
  );

  /// Cheap setting for tests only.
  static const Argon2Cost test = Argon2Cost(
    memoryKiB: 64,
    iterations: 1,
    lanes: 1,
  );

  final int memoryKiB;
  final int iterations;
  final int lanes;
}

/// Raw argon2id (RFC 9106). Pure and synchronous: call through [Isolate.run]
/// on the server so a login never blocks the event loop.
Uint8List argon2id(
  List<int> password,
  List<int> salt, {
  required Argon2Cost cost,
  int length = 32,
  List<int>? secret,
  List<int>? associatedData,
}) {
  final generator = Argon2BytesGenerator()
    ..init(
      Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        Uint8List.fromList(salt),
        desiredKeyLength: length,
        iterations: cost.iterations,
        memory: cost.memoryKiB,
        lanes: cost.lanes,
        version: Argon2Parameters.ARGON2_VERSION_13,
        secret: secret == null ? null : Uint8List.fromList(secret),
        additional: associatedData == null
            ? null
            : Uint8List.fromList(associatedData),
      ),
    );
  final out = Uint8List(length);
  generator.deriveKey(Uint8List.fromList(password), 0, out, 0);
  return out;
}

/// A parsed `$argon2id$v=19$m=..,t=..,p=..$salt$hash` string.
final class PhcHash {
  const PhcHash({required this.cost, required this.salt, required this.hash});

  /// Parses a PHC string; throws [FormatException] when it is not argon2id v19.
  factory PhcHash.parse(String text) {
    final parts = text.split(r'$');
    if (parts.length != 6 ||
        parts[0].isNotEmpty ||
        parts[1] != 'argon2id' ||
        parts[2] != 'v=19') {
      throw const FormatException('not an argon2id v19 PHC string');
    }
    final params = <String, int>{};
    for (final kv in parts[3].split(',')) {
      final i = kv.indexOf('=');
      final v = i < 0 ? null : int.tryParse(kv.substring(i + 1));
      if (v == null || v <= 0) {
        throw const FormatException('bad argon2 parameter');
      }
      params[kv.substring(0, i)] = v;
    }
    final m = params['m'];
    final t = params['t'];
    final p = params['p'];
    if (m == null || t == null || p == null) {
      throw const FormatException('missing m/t/p');
    }
    if (m > 1024 * 1024 || t > 64 || p > 64) {
      throw const FormatException('argon2 cost too high');
    }
    return PhcHash(
      cost: Argon2Cost(memoryKiB: m, iterations: t, lanes: p),
      salt: b64NoPadDecode(parts[4]),
      hash: b64NoPadDecode(parts[5]),
    );
  }

  final Argon2Cost cost;
  final Uint8List salt;
  final Uint8List hash;

  @override
  String toString() =>
      '\$argon2id\$v=19\$m=${cost.memoryKiB},t=${cost.iterations},p=${cost.lanes}'
      '\$${b64NoPad(salt)}\$${b64NoPad(hash)}';
}

/// Hashes [password] into a PHC string (synchronous; use [hashPasswordAsync]
/// in the server).
String hashPassword(String password, {Argon2Cost cost = Argon2Cost.password}) {
  final salt = randomBytes(16);
  final hash = argon2id(utf8.encode(password), salt, cost: cost);
  return PhcHash(cost: cost, salt: salt, hash: hash).toString();
}

/// Verifies [password] against a PHC string in constant time.
bool verifyPassword(String password, String phc) {
  final PhcHash parsed;
  try {
    parsed = PhcHash.parse(phc);
  } on FormatException {
    return false;
  }
  final computed = argon2id(
    utf8.encode(password),
    parsed.salt,
    cost: parsed.cost,
    length: parsed.hash.length,
  );
  return constantTimeEquals(computed, parsed.hash);
}

/// [hashPassword] on a background isolate.
Future<String> hashPasswordAsync(
  String password, {
  Argon2Cost cost = Argon2Cost.password,
}) => Isolate.run(() => hashPassword(password, cost: cost));

/// [verifyPassword] on a background isolate.
Future<bool> verifyPasswordAsync(String password, String phc) =>
    Isolate.run(() => verifyPassword(password, phc));

/// Why a new password was rejected.
enum PasswordProblem { tooShort, common }

/// docs/05: at least 12 characters and not in the 10 000 most common
/// passwords. Returns null when acceptable.
PasswordProblem? checkPasswordStrength(String password) {
  if (password.runes.length < 12) return PasswordProblem.tooShort;
  if (commonPasswords.contains(password.toLowerCase())) {
    return PasswordProblem.common;
  }
  return null;
}

/// Alphabet for generated passwords and codes: no 0/O, 1/I/L.
const String safeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

/// A strong random password like `K7QM2-XPLA9-R4TNC-8VWHZ` (~99 bits).
String generatePassword({int groups = 4}) {
  final bytes = randomBytes(groups * 5);
  final chars = [for (final b in bytes) safeAlphabet[b % safeAlphabet.length]];
  final parts = <String>[];
  for (var i = 0; i < groups; i++) {
    parts.add(chars.sublist(i * 5, i * 5 + 5).join());
  }
  return parts.join('-');
}
