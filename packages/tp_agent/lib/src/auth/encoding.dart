import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Unpadded standard base64, as used in PHC strings.
String b64NoPad(List<int> bytes) => base64Encode(bytes).replaceAll('=', '');

/// Decodes unpadded (or padded) standard base64.
Uint8List b64NoPadDecode(String text) {
  final pad = (4 - text.length % 4) % 4;
  return base64Decode(text + '=' * pad);
}

/// Unpadded base64url, as used by WebAuthn.
String b64Url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Decodes unpadded base64url; throws [FormatException] when invalid.
Uint8List b64UrlDecode(String text) {
  final pad = (4 - text.length % 4) % 4;
  return base64Url.decode(text + '=' * pad);
}

/// Cryptographically secure random bytes.
Uint8List randomBytes(int length, [Random? random]) {
  final r = random ?? Random.secure();
  return Uint8List.fromList(List<int>.generate(length, (_) => r.nextInt(256)));
}

/// Compares two byte lists in time independent of where they differ.
bool constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Constant-time comparison of two strings (as UTF-8).
bool constantTimeEqualsString(String a, String b) =>
    constantTimeEquals(utf8.encode(a), utf8.encode(b));

const String _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// RFC 4648 base32 without padding (TOTP secrets).
String base32Encode(List<int> bytes) {
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final b in bytes) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(_base32Alphabet[(buffer >> bits) & 31]);
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_base32Alphabet[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

/// Decodes RFC 4648 base32, ignoring case, spaces, dashes and padding.
Uint8List base32Decode(String text) {
  final clean = text.toUpperCase().replaceAll(RegExp(r'[\s=-]'), '');
  final out = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final ch in clean.split('')) {
    final v = _base32Alphabet.indexOf(ch);
    if (v < 0) throw FormatException('invalid base32 character', text);
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xFF);
      buffer &= (1 << bits) - 1;
    }
  }
  return Uint8List.fromList(out);
}
