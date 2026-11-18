import 'dart:convert';
import 'dart:typed_data';

/// Thrown for malformed or unsupported CBOR.
final class CborException implements Exception {
  const CborException(this.message);

  final String message;

  @override
  String toString() => 'CborException: $message';
}

/// Strict decoder for the CBOR subset used by WebAuthn (RFC 8949): integers,
/// byte and text strings, arrays, maps, false/true/null. Indefinite lengths,
/// tags and floats are rejected; nesting and sizes are capped. Written in
/// house instead of pulling in a general CBOR package (ADR-017).
final class CborDecoder {
  CborDecoder(this._bytes, {this.maxDepth = 16, this.maxItems = 4096});

  final Uint8List _bytes;
  final int maxDepth;
  final int maxItems;
  int _pos = 0;
  int _items = 0;

  /// Offset of the next unread byte.
  int get offset => _pos;

  /// Decodes one value (more bytes may follow; see [offset]).
  Object? decode() => _value(0);

  /// Decodes [bytes] as exactly one value.
  static Object? decodeAll(Uint8List bytes) {
    final d = CborDecoder(bytes);
    final v = d.decode();
    if (d.offset != bytes.length) throw const CborException('trailing bytes');
    return v;
  }

  int _byte() {
    if (_pos >= _bytes.length) throw const CborException('unexpected end');
    return _bytes[_pos++];
  }

  int _argument(int info) {
    if (info < 24) return info;
    final len = switch (info) {
      24 => 1,
      25 => 2,
      26 => 4,
      27 => 8,
      _ => throw const CborException('indefinite or reserved length'),
    };
    if (_pos + len > _bytes.length) throw const CborException('unexpected end');
    var v = 0;
    for (var i = 0; i < len; i++) {
      v = v * 256 + _bytes[_pos++];
    }
    if (len == 8 && v < 0) throw const CborException('integer too large');
    return v;
  }

  Uint8List _take(int n) {
    if (n < 0 || _pos + n > _bytes.length) {
      throw const CborException('length beyond input');
    }
    final out = Uint8List.sublistView(_bytes, _pos, _pos + n);
    _pos += n;
    return out;
  }

  Object? _value(int depth) {
    if (depth > maxDepth) throw const CborException('nesting too deep');
    if (++_items > maxItems) throw const CborException('too many items');
    final initial = _byte();
    final major = initial >> 5;
    final info = initial & 0x1F;
    switch (major) {
      case 0:
        return _argument(info);
      case 1:
        return -1 - _argument(info);
      case 2:
        return Uint8List.fromList(_take(_argument(info)));
      case 3:
        try {
          return utf8.decode(_take(_argument(info)));
        } on FormatException {
          throw const CborException('invalid UTF-8');
        }
      case 4:
        final n = _argument(info);
        if (n > maxItems) throw const CborException('array too long');
        return [for (var i = 0; i < n; i++) _value(depth + 1)];
      case 5:
        final n = _argument(info);
        if (n > maxItems) throw const CborException('map too long');
        final map = <Object?, Object?>{};
        for (var i = 0; i < n; i++) {
          final k = _value(depth + 1);
          if (k is! int && k is! String) {
            throw const CborException('unsupported map key');
          }
          if (map.containsKey(k)) {
            throw const CborException('duplicate map key');
          }
          map[k] = _value(depth + 1);
        }
        return map;
      case 6:
        throw const CborException('tags are not supported');
      default:
        return switch (info) {
          20 => false,
          21 => true,
          22 => null,
          _ => throw const CborException(
            'floats and other simple values are not supported',
          ),
        };
    }
  }
}

/// Minimal CBOR encoder (same subset), used by tests and challenges.
Uint8List cborEncode(Object? value) {
  final out = BytesBuilder();
  void head(int major, int arg) {
    if (arg < 24) {
      out.addByte((major << 5) | arg);
    } else if (arg < 0x100) {
      out
        ..addByte((major << 5) | 24)
        ..addByte(arg);
    } else if (arg < 0x10000) {
      out
        ..addByte((major << 5) | 25)
        ..addByte(arg >> 8)
        ..addByte(arg & 0xFF);
    } else {
      out.addByte((major << 5) | 26);
      for (var s = 24; s >= 0; s -= 8) {
        out.addByte((arg >> s) & 0xFF);
      }
    }
  }

  void write(Object? v) {
    switch (v) {
      case null:
        out.addByte(0xF6);
      case final bool b:
        out.addByte(b ? 0xF5 : 0xF4);
      case final int i when i >= 0:
        head(0, i);
      case final int i:
        head(1, -1 - i);
      case final Uint8List b:
        head(2, b.length);
        out.add(b);
      case final String s:
        final b = utf8.encode(s);
        head(3, b.length);
        out.add(b);
      case final List<Object?> l:
        head(4, l.length);
        l.forEach(write);
      case final Map<Object?, Object?> m:
        head(5, m.length);
        m.forEach((k, val) {
          write(k);
          write(val);
        });
      default:
        throw ArgumentError.value(v, 'value', 'unsupported CBOR type');
    }
  }

  write(value);
  return out.takeBytes();
}
