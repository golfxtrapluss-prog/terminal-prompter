import 'dart:convert';
import 'dart:typed_data';

import 'encoding.dart';
import 'password.dart';

/// A freshly generated set: [codes] are shown once, [stored] is persisted.
final class GeneratedBackupCodes {
  const GeneratedBackupCodes(this.codes, this.stored);

  final List<String> codes;
  final BackupCodeSet stored;
}

/// Hashed backup codes (docs/17 "Reservekoder").
///
/// All codes in a set share one random salt, so checking a guess costs one
/// argon2id computation regardless of how many codes remain. That is safe
/// because each code is a random ~49-bit secret, not a user-chosen value.
final class BackupCodeSet {
  BackupCodeSet({
    required this.salt,
    required this.hashes,
    required this.generated,
    required this.cost,
  });

  /// Generates [count] codes like `7KQ2M-X9PLA`.
  static GeneratedBackupCodes generate({
    int count = 10,
    Argon2Cost cost = Argon2Cost.backupCode,
    DateTime? now,
  }) {
    final salt = randomBytes(16);
    final codes = <String>[];
    final hashes = <Uint8List>[];
    while (codes.length < count) {
      final bytes = randomBytes(10);
      final raw = [
        for (final b in bytes) safeAlphabet[b % safeAlphabet.length],
      ].join();
      if (codes.any((c) => normalize(c) == raw)) continue;
      codes.add('${raw.substring(0, 5)}-${raw.substring(5)}');
      hashes.add(argon2id(utf8.encode(raw), salt, cost: cost));
    }
    return GeneratedBackupCodes(
      codes,
      BackupCodeSet(
        salt: salt,
        hashes: hashes,
        generated: now ?? DateTime.now().toUtc(),
        cost: cost,
      ),
    );
  }

  final Uint8List salt;
  final List<Uint8List> hashes;
  final DateTime generated;
  final Argon2Cost cost;

  /// Codes still unused.
  int get remaining => hashes.length;

  /// Upper-case, strips spaces and dashes, maps look-alikes (O→0 is not in
  /// the alphabet, so only case and separators matter).
  static String normalize(String code) =>
      code.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');

  /// Returns the index of the matching code, or null. Pure; call through an
  /// isolate in the server.
  int? match(String code) {
    final raw = normalize(code);
    if (raw.length != 10) return null;
    final candidate = argon2id(utf8.encode(raw), salt, cost: cost);
    int? found;
    for (var i = 0; i < hashes.length; i++) {
      if (constantTimeEquals(candidate, hashes[i]) && found == null) found = i;
    }
    return found;
  }

  /// Removes the code at [index] (it worked once and never again).
  void consume(int index) => hashes.removeAt(index);

  Map<String, Object?> toJson() => {
    'salt': b64NoPad(salt),
    'hashes': [for (final h in hashes) b64NoPad(h)],
    'generated': generated.toIso8601String(),
    'm': cost.memoryKiB,
    't': cost.iterations,
    'p': cost.lanes,
  };

  static BackupCodeSet fromJson(Map<String, Object?> json) {
    final hashes = json['hashes'];
    if (hashes is! List) throw const FormatException('backup codes: hashes');
    return BackupCodeSet(
      salt: b64NoPadDecode(json['salt']! as String),
      hashes: [for (final h in hashes) b64NoPadDecode(h as String)],
      generated: DateTime.parse(json['generated']! as String),
      cost: Argon2Cost(
        memoryKiB: json['m']! as int,
        iterations: json['t']! as int,
        lanes: json['p']! as int,
      ),
    );
  }
}
