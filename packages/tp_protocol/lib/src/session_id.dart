import 'dart:math';
import 'dart:typed_data';

import 'limits.dart';

const String _alphabet = 'abcdefghijklmnopqrstuvwxyz234567';

/// 128-bit random session identifier (docs/02).
///
/// Wire formats: 16 raw bytes in binary frames, lowercase unpadded base32
/// (26 characters) in JSON and URLs.
final class SessionId {
  /// Wraps a copy of [bytes], which must be exactly 16 bytes.
  SessionId(List<int> bytes)
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView() {
    if (bytes.length != Limits.sessionIdBytes) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'must be ${Limits.sessionIdBytes} bytes',
      );
    }
  }

  /// Generates a new id from [random] (defaults to [Random.secure]).
  factory SessionId.random([Random? random]) {
    final r = random ?? Random.secure();
    return SessionId(
      List<int>.generate(Limits.sessionIdBytes, (_) => r.nextInt(256)),
    );
  }

  /// Parses the base32 text form; throws [FormatException] when invalid.
  factory SessionId.parse(String text) {
    final id = tryParse(text);
    if (id == null) throw FormatException('invalid session id', text);
    return id;
  }

  /// Length of the text form.
  static const int textLength = 26;

  /// Parses the base32 text form, or returns null when invalid.
  static SessionId? tryParse(String text) {
    if (text.length != textLength) return null;
    final out = Uint8List(Limits.sessionIdBytes);
    var buffer = 0;
    var bits = 0;
    var n = 0;
    for (final rune in text.toLowerCase().codeUnits) {
      final value = _alphabet.indexOf(String.fromCharCode(rune));
      if (value < 0) return null;
      buffer = (buffer << 5) | value;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        if (n < out.length) out[n++] = (buffer >> bits) & 0xFF;
        buffer &= (1 << bits) - 1;
      }
    }
    return n == out.length ? SessionId(out) : null;
  }

  /// The raw 16 bytes (read-only view).
  final Uint8List bytes;

  String? _text;

  /// Base32 text form.
  @override
  String toString() => _text ??= _encode(bytes);

  @override
  bool operator ==(Object other) =>
      other is SessionId && toString() == other.toString();

  @override
  int get hashCode => toString().hashCode;

  static String _encode(Uint8List bytes) {
    final out = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final b in bytes) {
      buffer = (buffer << 8) | b;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out.write(_alphabet[(buffer >> bits) & 31]);
        buffer &= (1 << bits) - 1;
      }
    }
    if (bits > 0) out.write(_alphabet[(buffer << (5 - bits)) & 31]);
    return out.toString();
  }
}
