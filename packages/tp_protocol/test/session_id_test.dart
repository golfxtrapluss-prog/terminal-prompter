import 'dart:math';

import 'package:test/test.dart';
import 'package:tp_protocol/tp_protocol.dart';

void main() {
  test('text form is 26 lowercase base32 chars and round-trips', () {
    final rng = Random(7);
    for (var i = 0; i < 200; i++) {
      final id = SessionId.random(rng);
      final text = id.toString();
      expect(text, hasLength(26));
      expect(text, matches(RegExp(r'^[a-z2-7]{26}$')));
      final back = SessionId.parse(text);
      expect(back.bytes, id.bytes);
      expect(back, id);
      expect(back.hashCode, id.hashCode);
    }
  });

  test('parse is case-insensitive and rejects bad input', () {
    final id = SessionId.random(Random(1));
    expect(SessionId.parse(id.toString().toUpperCase()), id);
    expect(SessionId.tryParse(''), isNull);
    expect(SessionId.tryParse('${id}a'), isNull);
    expect(SessionId.tryParse(id.toString().replaceRange(0, 1, '1')), isNull);
    expect(() => SessionId.parse('nope'), throwsFormatException);
  });

  test('known vector', () {
    final id = SessionId(List.filled(16, 0));
    expect(id.toString(), 'a' * 26);
    final ff = SessionId(List.filled(16, 0xff));
    expect(ff.toString(), '${'7' * 25}4'); // trailing 3 bits padded
  });

  test('bytes are read-only and length is enforced', () {
    final id = SessionId(List.generate(16, (i) => i));
    expect(() => id.bytes[0] = 9, throwsUnsupportedError);
    expect(() => SessionId([1, 2, 3]), throwsArgumentError);
  });
}
