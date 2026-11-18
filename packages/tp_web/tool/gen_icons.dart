/// Generates the PWA icons (`web/icons/*.png`) without any image library:
/// a dark rounded tile with a green prompt chevron and cursor block.
///
/// Usage: `dart run tool/gen_icons.dart` from `packages/tp_web`.
library;

import 'dart:io';
import 'dart:typed_data';

void main() {
  for (final (name, size) in [
    ('icon-192', 192),
    ('icon-512', 512),
    ('apple-touch-icon', 180),
  ]) {
    final png = _encodePng(size, size, _draw(size));
    File('web/icons/$name.png').writeAsBytesSync(png);
    stdout.writeln('wrote web/icons/$name.png (${png.length} bytes)');
  }
}

/// RGBA pixels for the icon.
Uint8List _draw(int size) {
  final px = Uint8List(size * size * 4);
  const bg = (0x0d, 0x11, 0x17);
  const panel = (0x16, 0x1b, 0x22);
  const green = (0x3f, 0xb9, 0x50);
  const blue = (0x58, 0xa6, 0xff);
  final radius = size * 0.18;
  final inset = size * 0.08;

  void put(int x, int y, (int, int, int) c) {
    final i = (y * size + x) * 4;
    px[i] = c.$1;
    px[i + 1] = c.$2;
    px[i + 2] = c.$3;
    px[i + 3] = 255;
  }

  bool inRounded(
    double x,
    double y,
    double x0,
    double y0,
    double x1,
    double y1,
    double r,
  ) {
    if (x < x0 || x > x1 || y < y0 || y > y1) return false;
    final cx = x < x0 + r ? x0 + r : (x > x1 - r ? x1 - r : x);
    final cy = y < y0 + r ? y0 + r : (y > y1 - r ? y1 - r : y);
    final dx = x - cx;
    final dy = y - cy;
    return dx * dx + dy * dy <= r * r;
  }

  // Chevron ">" as two thick strokes, cursor block to the right.
  final stroke = size * 0.09;
  final cx0 = size * 0.26;
  final cy0 = size * 0.33;
  final cxm = size * 0.47;
  final cym = size * 0.50;
  final cy1 = size * 0.67;

  double distToSegment(
    double x,
    double y,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final vx = bx - ax;
    final vy = by - ay;
    final wx = x - ax;
    final wy = y - ay;
    final len2 = vx * vx + vy * vy;
    var t = len2 == 0 ? 0.0 : (wx * vx + wy * vy) / len2;
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    final dx = x - (ax + t * vx);
    final dy = y - (ay + t * vy);
    return (dx * dx + dy * dy);
  }

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final fx = x + 0.5;
      final fy = y + 0.5;
      (int, int, int) c = bg;
      if (inRounded(fx, fy, 0, 0, size.toDouble(), size.toDouble(), radius)) {
        c =
            inRounded(
              fx,
              fy,
              inset,
              inset,
              size - inset,
              size - inset,
              radius * 0.7,
            )
            ? panel
            : bg;
        final d1 = distToSegment(fx, fy, cx0, cy0, cxm, cym);
        final d2 = distToSegment(fx, fy, cxm, cym, cx0, cy1);
        if (d1 <= stroke * stroke / 4 || d2 <= stroke * stroke / 4) c = green;
        if (fx >= size * 0.56 &&
            fx <= size * 0.76 &&
            fy >= size * 0.58 &&
            fy <= size * 0.68) {
          c = blue;
        }
      }
      put(x, y, c);
    }
  }
  return px;
}

Uint8List _encodePng(int width, int height, Uint8List rgba) {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // filter: none
    raw.add(Uint8List.sublistView(rgba, y * width * 4, (y + 1) * width * 4));
  }
  final compressed = ZLibEncoder(level: 9).convert(raw.takeBytes());
  final out = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6) // RGBA
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  _chunk(out, 'IHDR', ihdr.buffer.asUint8List());
  _chunk(out, 'IDAT', Uint8List.fromList(compressed));
  _chunk(out, 'IEND', Uint8List(0));
  return out.takeBytes();
}

void _chunk(BytesBuilder out, String type, Uint8List data) {
  final len = ByteData(4)..setUint32(0, data.length);
  out.add(len.buffer.asUint8List());
  final typeBytes = Uint8List.fromList(type.codeUnits);
  out.add(typeBytes);
  out.add(data);
  final crc = ByteData(4)..setUint32(0, _crc32(typeBytes, data));
  out.add(crc.buffer.asUint8List());
}

final List<int> _crcTable = List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(Uint8List a, Uint8List b) {
  var c = 0xffffffff;
  for (final byte in a) {
    c = _crcTable[(c ^ byte) & 0xff] ^ (c >> 8);
  }
  for (final byte in b) {
    c = _crcTable[(c ^ byte) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}
