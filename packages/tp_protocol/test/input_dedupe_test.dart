import 'package:test/test.dart';
import 'package:tp_protocol/tp_protocol.dart';

void main() {
  test('detects duplicates per instance only', () {
    final d = InputDeduper();
    expect(d.isDuplicate('a', 1), isFalse);
    expect(d.isDuplicate('a', 1), isTrue);
    expect(d.isDuplicate('b', 1), isFalse);
    expect(d.isDuplicate('a', 2), isFalse);
    expect(d.instanceCount, 2);
  });

  test('forgets ids older than the window', () {
    final d = InputDeduper(capacity: 3);
    for (var i = 1; i <= 4; i++) {
      d.isDuplicate('a', i);
    }
    expect(d.isDuplicate('a', 1), isFalse, reason: 'evicted');
    expect(d.isDuplicate('a', 4), isTrue);
  });

  test('forget drops an instance', () {
    final d = InputDeduper()..isDuplicate('a', 1);
    d.forget('a');
    expect(d.isDuplicate('a', 1), isFalse);
  });
}
