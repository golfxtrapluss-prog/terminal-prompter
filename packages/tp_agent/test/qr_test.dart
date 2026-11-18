import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tp_agent/src/cli/qr.dart';

/// Reference matrices were produced with the `segno` Python library
/// (version and mask pinned, error correction M, byte mode, UTF-8) and
/// cross-checked module for module against the `qrcode` library. segno 1.6
/// appends 8 zero bits when the bit stream already ends on a byte boundary,
/// contrary to ISO/IEC 18004 §7.4.10; that one function was patched to the
/// standard (`(-length) % 8`) before generating, which made both libraries
/// agree. The automatic mask choice is checked against the qrcode library's
/// penalty scores (segno and qrcode pick masks by slightly different rules).
void main() {
  final fixtures =
      (jsonDecode(File('test/fixtures/qr_reference.json').readAsStringSync())
              as List)
          .cast<Map<String, Object?>>();

  for (final f in fixtures) {
    final text = f['text']! as String;
    final version = f['version']! as int;
    final mask = f['mask']! as int;
    final auto = f['auto'] == true;
    test(
      'v$version mask $mask${auto ? ' (auto)' : ''} matches the reference',
      () {
        final qr = auto
            ? QrCode.encode(text)
            : QrCode.encode(text, version: version, mask: mask);
        expect(qr.version, version);
        if (auto) {
          expect(qr.mask, mask, reason: 'same mask choice as the reference');
        }
        final rows = [
          for (final r in qr.modules) r.map((m) => m ? '1' : '0').join(),
        ];
        expect(rows, f['rows']);
      },
    );
  }

  test('picks the smallest version and renders two rows per line', () {
    final qr = QrCode.encode('HELLO');
    expect(qr.version, 1);
    final lines = qr.toTerminal().trimRight().split('\n');
    expect(lines.length, (21 + 4 + 1) ~/ 2);
    expect(lines.first.runes.length, 21 + 4);
  });

  test('rejects text that does not fit version 10', () {
    expect(() => QrCode.encode('z' * 300), throwsArgumentError);
  });
}
