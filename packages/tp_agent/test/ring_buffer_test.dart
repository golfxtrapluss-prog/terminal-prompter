import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tp_agent/tp_agent.dart';

void main() {
  test('empty buffer', () {
    final rb = RingBuffer(8);
    expect(rb.seq, 0);
    expect(rb.length, 0);
    expect(rb.oldestSeq, 0);
    final r = rb.readFrom(0);
    expect(r.data, isEmpty);
    expect(r.startSeq, 0);
    expect(r.truncated, isNull);
  });

  test('write then read back from 0 and from the tip', () {
    final rb = RingBuffer(16)..write([1, 2, 3, 4, 5]);
    expect(rb.seq, 5);
    expect(rb.readFrom(0).data, [1, 2, 3, 4, 5]);
    expect(rb.readFrom(3).data, [4, 5]);
    expect(rb.readFrom(5).data, isEmpty);
    expect(rb.readFrom(2).endSeq, 5);
  });

  test('wrap-around reports truncation for overwritten bytes', () {
    final rb = RingBuffer(8)
      ..write([0, 1, 2, 3, 4])
      ..write([5, 6, 7, 8, 9]);
    expect(rb.seq, 10);
    expect(rb.length, 8);
    expect(rb.oldestSeq, 2);

    final r = rb.readFrom(0);
    expect(r.truncated, (from: 0, to: 2));
    expect(r.startSeq, 2);
    expect(r.data, [2, 3, 4, 5, 6, 7, 8, 9]);

    final tail = rb.readFrom(6);
    expect(tail.truncated, isNull);
    expect(tail.data, [6, 7, 8, 9]);
  });

  test('write larger than capacity keeps only the tail', () {
    final rb = RingBuffer(4)..write(List.generate(10, (i) => i));
    expect(rb.seq, 10);
    expect(rb.length, 4);
    expect(rb.oldestSeq, 6);
    expect(rb.readFrom(6).data, [6, 7, 8, 9]);
    expect(rb.readFrom(0).truncated, (from: 0, to: 6));
  });

  test('position beyond seq yields nothing at seq', () {
    final rb = RingBuffer(4)..write([1, 2]);
    final r = rb.readFrom(99);
    expect(r.data, isEmpty);
    expect(r.startSeq, 2);
    expect(r.truncated, isNull);
  });

  test('negative position is rejected', () {
    expect(() => RingBuffer(4).readFrom(-1), throwsRangeError);
  });

  test('random writes match a reference log', () {
    final rng = Random(42);
    const cap = 37;
    final rb = RingBuffer(cap);
    final log = <int>[];
    for (var round = 0; round < 500; round++) {
      final chunk = Uint8List.fromList(
        List.generate(rng.nextInt(60), (_) => rng.nextInt(256)),
      );
      rb.write(chunk);
      log.addAll(chunk);
      expect(rb.seq, log.length);
      expect(rb.length, min(cap, log.length));

      final from = rng.nextInt(log.length + 3);
      final r = rb.readFrom(from);
      final expectedStart = max(min(from, log.length), log.length - rb.length);
      expect(r.startSeq, expectedStart);
      expect(r.data, log.sublist(expectedStart));
      if (from < rb.oldestSeq) {
        expect(r.truncated, (from: from, to: rb.oldestSeq));
      } else {
        expect(r.truncated, isNull);
      }
    }
  });
}
