import 'dart:math';

import 'package:test/test.dart';
import 'package:tp_protocol/tp_protocol.dart';

void main() {
  test(
    'follows the 0.5/1/2/4/8/10 schedule within jitter and caps at 10 s',
    () {
      final backoff = Backoff(random: Random(1));
      final expected = [0.5, 1, 2, 4, 8, 10, 10, 10];
      for (var i = 0; i < expected.length; i++) {
        final ms = backoff.delay(i).inMilliseconds;
        expect(
          ms,
          inInclusiveRange(expected[i] * 750, expected[i] * 1250),
          reason: 'attempt $i',
        );
      }
    },
  );

  test('scale shortens delays', () {
    final backoff = Backoff(random: Random(2), scale: 0.01);
    expect(backoff.delay(5).inMilliseconds, lessThanOrEqualTo(125));
  });

  test('negative attempt is treated as the first', () {
    expect(
      Backoff(random: Random(3)).delay(-4).inMilliseconds,
      lessThanOrEqualTo(625),
    );
  });
}
