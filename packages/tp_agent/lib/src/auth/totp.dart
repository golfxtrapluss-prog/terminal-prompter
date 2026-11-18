import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'encoding.dart';

/// RFC 6238 TOTP with HMAC-SHA1, 30 s steps, 6 digits (docs/05).
final class Totp {
  Totp(this.secret, {this.digits = 6, this.period = 30});

  /// Parses a base32 secret.
  factory Totp.fromBase32(String secret) => Totp(base32Decode(secret));

  /// Generates a new 160-bit secret.
  factory Totp.generate() => Totp(randomBytes(20));

  final Uint8List secret;
  final int digits;
  final int period;

  /// Secret in base32 (for config and authenticator apps).
  String get base32Secret => base32Encode(secret);

  /// Time step for [time].
  int stepAt(DateTime time) => time.millisecondsSinceEpoch ~/ 1000 ~/ period;

  /// Code for [step] (RFC 4226 HOTP).
  String codeForStep(int step) {
    final counter = ByteData(8)
      ..setUint32(0, step ~/ 0x100000000)
      ..setUint32(4, step & 0xFFFFFFFF);
    final mac = Hmac(sha1, secret).convert(counter.buffer.asUint8List()).bytes;
    final offset = mac[mac.length - 1] & 0x0F;
    final binary =
        ((mac[offset] & 0x7F) << 24) |
        (mac[offset + 1] << 16) |
        (mac[offset + 2] << 8) |
        mac[offset + 3];
    var mod = 1;
    for (var i = 0; i < digits; i++) {
      mod *= 10;
    }
    return (binary % mod).toString().padLeft(digits, '0');
  }

  /// Code valid at [time].
  String codeAt(DateTime time) => codeForStep(stepAt(time));

  /// Checks [code] against the steps around [time] (±[window]). Returns the
  /// matching step, or null. Steps at or before [lastUsedStep] are refused
  /// so a code cannot be replayed.
  int? verify(String code, DateTime time, {int window = 1, int? lastUsedStep}) {
    final clean = code.replaceAll(RegExp(r'\s'), '');
    if (clean.length != digits || int.tryParse(clean) == null) return null;
    final now = stepAt(time);
    int? match;
    for (var s = now - window; s <= now + window; s++) {
      // Compare every candidate so timing does not reveal the position.
      final ok = constantTimeEqualsString(codeForStep(s), clean);
      if (ok && match == null) match = s;
    }
    if (match == null) return null;
    if (lastUsedStep != null && match <= lastUsedStep) return null;
    return match;
  }

  /// `otpauth://` URI for authenticator apps.
  String uri({required String account, String issuer = 'Terminal Prompter'}) {
    final label = Uri.encodeComponent('$issuer:$account');
    final q = Uri(
      queryParameters: {
        'secret': base32Secret,
        'issuer': issuer,
        'algorithm': 'SHA1',
        'digits': '$digits',
        'period': '$period',
      },
    ).query;
    return 'otpauth://totp/$label?$q';
  }
}
