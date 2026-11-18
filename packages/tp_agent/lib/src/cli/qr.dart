import 'dart:convert';

/// Minimal QR code encoder for showing a TOTP `otpauth://` URI in a
/// terminal (docs/02 `tp-agent totp enable`): byte mode, error correction
/// level M, versions 1–10 (up to 213 bytes). Verified against a reference
/// encoder in test/qr_test.dart.
final class QrCode {
  QrCode._(this.version, this.mask, this.modules);

  /// Encodes [text]. [version] and [mask] are chosen automatically unless
  /// given (tests pin them to compare with reference output).
  factory QrCode.encode(String text, {int? version, int? mask}) {
    final data = utf8.encode(text);
    final v = version ?? _smallestVersion(data.length);
    if (v < 1 || v > 10) {
      throw ArgumentError.value(version, 'version', 'must be 1..10');
    }
    if (_capacityBytes(v) < data.length) {
      throw ArgumentError(
        'text too long for version $v (max ${_capacityBytes(v)} bytes)',
      );
    }
    final codewords = _interleave(v, _dataCodewords(v, data));
    final base = _Matrix(v)..placeFunctionPatterns();
    base.placeData(codewords);
    if (mask != null) {
      return QrCode._(
        v,
        mask,
        (base.copy()
              ..applyMask(mask)
              ..placeFormat(mask))
            .modules,
      );
    }
    var bestMask = 0;
    var bestScore = 1 << 30;
    for (var m = 0; m < 8; m++) {
      final candidate = base.copy()
        ..applyMask(m)
        ..placeFormat(m);
      final score = candidate.penalty();
      if (score < bestScore) {
        bestScore = score;
        bestMask = m;
      }
    }
    return QrCode._(
      v,
      bestMask,
      (base.copy()
            ..applyMask(bestMask)
            ..placeFormat(bestMask))
          .modules,
    );
  }

  final int version;
  final int mask;

  /// `true` = dark module. Row-major, `size × size`.
  final List<List<bool>> modules;

  int get size => modules.length;

  /// Penalty for each mask on this content (diagnostics and tests).
  static List<int> penalties(String text) {
    final data = utf8.encode(text);
    final v = _smallestVersion(data.length);
    final base = _Matrix(v)
      ..placeFunctionPatterns()
      ..placeData(_interleave(v, _dataCodewords(v, data)));
    return [
      for (var m = 0; m < 8; m++)
        (base.copy()
              ..applyMask(m)
              ..placeFormat(m))
            .penalty(),
    ];
  }

  /// Renders with half-block characters, two module rows per text line.
  /// Light modules are drawn (block characters), dark ones are blank, which
  /// gives dark-on-light codes on the usual dark terminal background.
  String toTerminal({int quiet = 2}) {
    bool dark(int r, int c) =>
        r >= 0 && c >= 0 && r < size && c < size && modules[r][c];
    final out = StringBuffer();
    for (var r = -quiet; r < size + quiet; r += 2) {
      for (var c = -quiet; c < size + quiet; c++) {
        final top = !dark(r, c);
        final bottom = !dark(r + 1, c) && r + 1 < size + quiet;
        out.write(
          top && bottom
              ? '█'
              : top
              ? '▀'
              : bottom
              ? '▄'
              : ' ',
        );
      }
      out.writeln();
    }
    return out.toString();
  }

  // ---- tables for error correction level M ----

  /// (ec codewords per block, [(blocks, data codewords per block)]).
  static const List<(int, List<(int, int)>)> _blocksM = [
    (10, [(1, 16)]),
    (16, [(1, 28)]),
    (26, [(1, 44)]),
    (18, [(2, 32)]),
    (24, [(2, 43)]),
    (16, [(4, 27)]),
    (18, [(4, 31)]),
    (22, [(2, 38), (2, 39)]),
    (22, [(3, 36), (2, 37)]),
    (26, [(4, 43), (1, 44)]),
  ];

  static const List<List<int>> _alignment = [
    [],
    [6, 18],
    [6, 22],
    [6, 26],
    [6, 30],
    [6, 34],
    [6, 22, 38],
    [6, 24, 42],
    [6, 26, 46],
    [6, 28, 50],
  ];

  static int _dataCount(int v) =>
      [for (final (n, d) in _blocksM[v - 1].$2) n * d].reduce((a, b) => a + b);

  static int _countBits(int v) => v < 10 ? 8 : 16;

  static int _capacityBytes(int v) =>
      (_dataCount(v) * 8 - 4 - _countBits(v)) ~/ 8;

  static int _smallestVersion(int bytes) {
    for (var v = 1; v <= 10; v++) {
      if (_capacityBytes(v) >= bytes) return v;
    }
    throw ArgumentError(
      'text too long for a version 1-10 QR code ($bytes bytes)',
    );
  }

  static List<int> _dataCodewords(int v, List<int> data) {
    final bits = <int>[];
    void put(int value, int length) {
      for (var i = length - 1; i >= 0; i--) {
        bits.add((value >> i) & 1);
      }
    }

    put(0x4, 4); // byte mode
    put(data.length, _countBits(v));
    for (final b in data) {
      put(b, 8);
    }
    final capacity = _dataCount(v) * 8;
    put(0, (capacity - bits.length).clamp(0, 4)); // terminator
    while (bits.length % 8 != 0) {
      bits.add(0);
    }
    final out = <int>[
      for (var i = 0; i < bits.length; i += 8)
        int.parse(bits.sublist(i, i + 8).join(), radix: 2),
    ];
    for (var pad = 0; out.length < _dataCount(v); pad++) {
      out.add(pad.isEven ? 0xEC : 0x11);
    }
    return out;
  }

  static List<int> _interleave(int v, List<int> data) {
    final (ecLen, groups) = _blocksM[v - 1];
    final blocks = <List<int>>[];
    var offset = 0;
    for (final (count, size) in groups) {
      for (var i = 0; i < count; i++) {
        blocks.add(data.sublist(offset, offset + size));
        offset += size;
      }
    }
    final ecBlocks = [for (final b in blocks) _reedSolomon(b, ecLen)];
    final out = <int>[];
    final maxData = blocks.map((b) => b.length).reduce((a, b) => a > b ? a : b);
    for (var i = 0; i < maxData; i++) {
      for (final b in blocks) {
        if (i < b.length) out.add(b[i]);
      }
    }
    for (var i = 0; i < ecLen; i++) {
      for (final e in ecBlocks) {
        out.add(e[i]);
      }
    }
    return out;
  }

  // GF(256) with polynomial 0x11D.
  static final List<int> _exp = _buildExp();
  static final List<int> _log = _buildLog();

  static List<int> _buildExp() {
    final exp = List<int>.filled(512, 0);
    var x = 1;
    for (var i = 0; i < 255; i++) {
      exp[i] = x;
      x <<= 1;
      if (x & 0x100 != 0) x ^= 0x11D;
    }
    for (var i = 255; i < 512; i++) {
      exp[i] = exp[i - 255];
    }
    return exp;
  }

  static List<int> _buildLog() {
    final log = List<int>.filled(256, 0);
    for (var i = 0; i < 255; i++) {
      log[_exp[i]] = i;
    }
    return log;
  }

  static int _mul(int a, int b) =>
      a == 0 || b == 0 ? 0 : _exp[_log[a] + _log[b]];

  static List<int> _reedSolomon(List<int> data, int ecLen) {
    var gen = <int>[1];
    for (var i = 0; i < ecLen; i++) {
      final next = List<int>.filled(gen.length + 1, 0);
      for (var j = 0; j < gen.length; j++) {
        next[j] ^= gen[j];
        next[j + 1] ^= _mul(gen[j], _exp[i]);
      }
      gen = next;
    }
    final rem = List<int>.filled(ecLen, 0, growable: true);
    for (final d in data) {
      final factor = d ^ rem[0];
      rem
        ..removeAt(0)
        ..add(0);
      for (var j = 0; j < ecLen; j++) {
        rem[j] ^= _mul(gen[j + 1], factor);
      }
    }
    return rem;
  }
}

final class _Matrix {
  _Matrix(this.version)
    : size = version * 4 + 17,
      modules = List.generate(
        version * 4 + 17,
        (_) => List<bool>.filled(version * 4 + 17, false),
      ),
      reserved = List.generate(
        version * 4 + 17,
        (_) => List<bool>.filled(version * 4 + 17, false),
      );

  _Matrix._copy(this.version, this.size, this.modules, this.reserved);

  final int version;
  final int size;
  final List<List<bool>> modules;
  final List<List<bool>> reserved;

  _Matrix copy() => _Matrix._copy(version, size, [
    for (final r in modules) List<bool>.of(r),
  ], reserved);

  void _set(int r, int c, bool dark) {
    modules[r][c] = dark;
    reserved[r][c] = true;
  }

  void placeFunctionPatterns() {
    for (final (r, c) in [(0, 0), (0, size - 7), (size - 7, 0)]) {
      for (var dr = -1; dr <= 7; dr++) {
        for (var dc = -1; dc <= 7; dc++) {
          final rr = r + dr;
          final cc = c + dc;
          if (rr < 0 || cc < 0 || rr >= size || cc >= size) continue;
          final inRing = dr >= 0 && dr <= 6 && dc >= 0 && dc <= 6;
          final dark =
              inRing &&
              (dr == 0 ||
                  dr == 6 ||
                  dc == 0 ||
                  dc == 6 ||
                  (dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4));
          _set(rr, cc, dark);
        }
      }
    }
    for (var i = 8; i < size - 8; i++) {
      _set(6, i, i.isEven);
      _set(i, 6, i.isEven);
    }
    final centers = QrCode._alignment[version - 1];
    final last = centers.length - 1;
    for (var i = 0; i < centers.length; i++) {
      for (var j = 0; j < centers.length; j++) {
        // Only the three corners overlap finder patterns; centres on the
        // timing lines (row/column 6) are drawn over them.
        if ((i == 0 && j == 0) ||
            (i == 0 && j == last) ||
            (i == last && j == 0)) {
          continue;
        }
        final r = centers[i];
        final c = centers[j];
        for (var dr = -2; dr <= 2; dr++) {
          for (var dc = -2; dc <= 2; dc++) {
            final ring = dr.abs() == 2 || dc.abs() == 2;
            _set(r + dr, c + dc, ring || (dr == 0 && dc == 0));
          }
        }
      }
    }
    _set(size - 8, 8, true); // dark module
    // Reserve format areas (filled per mask).
    for (var i = 0; i < 9; i++) {
      if (!reserved[8][i]) _set(8, i, false);
      if (!reserved[i][8]) _set(i, 8, false);
    }
    for (var i = 0; i < 8; i++) {
      _set(8, size - 1 - i, false);
      if (!reserved[size - 1 - i][8]) _set(size - 1 - i, 8, false);
    }
    if (version >= 7) {
      final bits = _versionBits(version);
      for (var i = 0; i < 18; i++) {
        final dark = (bits >> i) & 1 == 1;
        final a = i ~/ 3;
        final b = size - 11 + i % 3;
        _set(a, b, dark);
        _set(b, a, dark);
      }
    }
  }

  void placeData(List<int> codewords) {
    final bits = <bool>[
      for (final cw in codewords)
        for (var i = 7; i >= 0; i--) (cw >> i) & 1 == 1,
    ];
    var index = 0;
    var upward = true;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (var n = 0; n < size; n++) {
        final row = upward ? size - 1 - n : n;
        for (var dc = 0; dc < 2; dc++) {
          final col = right - dc;
          if (reserved[row][col]) continue;
          modules[row][col] = index < bits.length && bits[index];
          index++;
        }
      }
      upward = !upward;
    }
  }

  static bool _maskBit(int mask, int r, int c) => switch (mask) {
    0 => (r + c) % 2 == 0,
    1 => r % 2 == 0,
    2 => c % 3 == 0,
    3 => (r + c) % 3 == 0,
    4 => (r ~/ 2 + c ~/ 3) % 2 == 0,
    5 => (r * c) % 2 + (r * c) % 3 == 0,
    6 => ((r * c) % 2 + (r * c) % 3) % 2 == 0,
    _ => ((r + c) % 2 + (r * c) % 3) % 2 == 0,
  };

  void applyMask(int mask) {
    for (var r = 0; r < size; r++) {
      for (var c = 0; c < size; c++) {
        if (!reserved[r][c] && _maskBit(mask, r, c)) {
          modules[r][c] = !modules[r][c];
        }
      }
    }
  }

  void placeFormat(int mask) {
    // Level M = 00.
    final data = (0 << 3) | mask;
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    final bits = ((data << 10) | rem) ^ 0x5412;
    bool bit(int i) => (bits >> i) & 1 == 1;
    // First copy, around the top-left finder (column 8 and row 8).
    for (var i = 0; i <= 5; i++) {
      modules[i][8] = bit(i);
    }
    modules[7][8] = bit(6);
    modules[8][8] = bit(7);
    modules[8][7] = bit(8);
    for (var i = 9; i < 15; i++) {
      modules[8][14 - i] = bit(i);
    }
    // Second copy, split between the top-right and bottom-left finders.
    for (var i = 0; i < 8; i++) {
      modules[8][size - 1 - i] = bit(i);
    }
    for (var i = 8; i < 15; i++) {
      modules[size - 15 + i][8] = bit(i);
    }
    modules[size - 8][8] = true;
  }

  static int _versionBits(int v) {
    var rem = v;
    for (var i = 0; i < 12; i++) {
      rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    }
    return (v << 12) | rem;
  }

  /// ISO/IEC 18004 mask penalty (rules 1–4).
  int penalty() {
    var score = 0;
    for (var pass = 0; pass < 2; pass++) {
      for (var a = 0; a < size; a++) {
        var run = 1;
        for (var b = 1; b < size; b++) {
          final cur = pass == 0 ? modules[a][b] : modules[b][a];
          final prev = pass == 0 ? modules[a][b - 1] : modules[b - 1][a];
          if (cur == prev) {
            run++;
          } else {
            if (run >= 5) score += 3 + run - 5;
            run = 1;
          }
        }
        if (run >= 5) score += 3 + run - 5;
      }
    }
    for (var r = 0; r < size - 1; r++) {
      for (var c = 0; c < size - 1; c++) {
        final v = modules[r][c];
        if (v == modules[r][c + 1] &&
            v == modules[r + 1][c] &&
            v == modules[r + 1][c + 1]) {
          score += 3;
        }
      }
    }
    const pattern = [
      true,
      false,
      true,
      true,
      true,
      false,
      true,
      false,
      false,
      false,
      false,
    ];
    const reversed = [
      false,
      false,
      false,
      false,
      true,
      false,
      true,
      true,
      true,
      false,
      true,
    ];
    for (var a = 0; a < size; a++) {
      for (var b = 0; b <= size - 11; b++) {
        for (final p in [pattern, reversed]) {
          var row = true;
          var col = true;
          for (var k = 0; k < 11; k++) {
            if (modules[a][b + k] != p[k]) row = false;
            if (modules[b + k][a] != p[k]) col = false;
          }
          if (row) score += 40;
          if (col) score += 40;
        }
      }
    }
    var dark = 0;
    for (final r in modules) {
      for (final m in r) {
        if (m) dark++;
      }
    }
    final percent = dark * 100 ~/ (size * size);
    score += ((percent - 50).abs() ~/ 5) * 10;
    return score;
  }
}
