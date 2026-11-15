import 'dart:math';

import 'limits.dart';

/// Reconnect backoff: 0.5/1/2/4/8/10 s with ±25 % jitter (docs/03).
///
/// Pure and deterministic given a [Random], so both the client and tests can
/// use it. [scale] shortens every delay (tests use a small value).
final class Backoff {
  /// Creates a schedule; [scale] multiplies every delay.
  Backoff({Random? random, this.scale = 1.0}) : _random = random ?? Random();

  final Random _random;

  /// Multiplier applied to every delay.
  final double scale;

  /// Delay before reconnect attempt number [attempt] (0 = first retry).
  Duration delay(int attempt) {
    final table = Limits.backoffSeconds;
    final base = table[attempt.clamp(0, table.length - 1)];
    final jitter = 1 + (_random.nextDouble() - 0.5) * 0.5; // 0.75 .. 1.25
    final ms = (base * jitter * scale * 1000).round();
    return Duration(milliseconds: max(ms, 0));
  }
}
