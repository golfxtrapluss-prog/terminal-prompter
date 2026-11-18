/// Sliding-window limiter for login attempts (docs/05): per client IP and
/// globally, plus a lockout after consecutive failed password logins.
final class LoginLimiter {
  LoginLimiter({
    this.perIp = 5,
    this.global = 30,
    this.window = const Duration(minutes: 1),
    required this.maxFailures,
    required this.lockout,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int perIp;
  final int global;
  final Duration window;
  final int maxFailures;
  final Duration lockout;
  final DateTime Function() _clock;
  final Map<String, List<DateTime>> _byIp = {};
  final List<DateTime> _all = [];
  int _consecutiveFailures = 0;
  DateTime? _lockedUntil;

  /// When a password lockout is active, its end; otherwise null.
  DateTime? get lockedUntil {
    final until = _lockedUntil;
    if (until != null && _clock().isAfter(until)) {
      _lockedUntil = null;
      _consecutiveFailures = 0;
    }
    return _lockedUntil;
  }

  /// Records an attempt from [ip]. Returns how long to wait when over the
  /// limit, or null when the attempt may proceed.
  Duration? attempt(String ip) {
    final now = _clock();
    final cutoff = now.subtract(window);
    final mine = _byIp.putIfAbsent(ip, () => [])
      ..removeWhere((t) => t.isBefore(cutoff));
    _all.removeWhere((t) => t.isBefore(cutoff));
    if (_byIp.length > 10000) _byIp.removeWhere((_, v) => v.isEmpty);
    if (mine.length >= perIp) return mine.first.add(window).difference(now);
    if (_all.length >= global) return _all.first.add(window).difference(now);
    mine.add(now);
    _all.add(now);
    return null;
  }

  /// A password/backup-code login failed. Returns true when this triggered
  /// a lockout.
  bool failure() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= maxFailures && _lockedUntil == null) {
      _lockedUntil = _clock().add(lockout);
      return true;
    }
    return false;
  }

  /// A login succeeded.
  void success() => _consecutiveFailures = 0;
}
