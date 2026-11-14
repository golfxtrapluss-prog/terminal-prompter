/// A set of simulated network conditions (docs/07 and docs/11).
///
/// Real packet loss cannot be reproduced in a userspace TCP proxy, so
/// [lossRate] is approximated with random stalls and resets.
final class NetProfile {
  /// Creates a profile. [rtt] is the full round-trip time; the proxy delays
  /// each direction by half of it.
  const NetProfile({
    required this.name,
    required this.rtt,
    this.jitter = Duration.zero,
    this.lossRate = 0,
    this.bandwidthBitsPerSecond,
    this.outageEvery,
    this.outageDuration = Duration.zero,
    this.blockWebSocketUpgrade = false,
    this.idleCutoff,
  }) : assert(lossRate >= 0 && lossRate <= 1, 'lossRate must be in 0..1');

  /// Short identifier used with `dart test --tags netsim` and in logs.
  final String name;

  /// Round-trip time.
  final Duration rtt;

  /// Symmetric jitter added to [rtt].
  final Duration jitter;

  /// Approximate fraction of traffic affected by stalls/resets (0..1).
  final double lossRate;

  /// Bandwidth cap, or null for unlimited.
  final int? bandwidthBitsPerSecond;

  /// If set, the link goes down for [outageDuration] at this interval.
  final Duration? outageEvery;

  /// Length of each scheduled outage.
  final Duration outageDuration;

  /// Reject HTTP `Upgrade: websocket` so clients must fall back to SSE.
  final bool blockWebSocketUpgrade;

  /// Close connections that are silent for this long (hostile proxies).
  final Duration? idleCutoff;

  /// Classic GEO VSAT: high latency, some loss, low bandwidth.
  static const NetProfile geo = NetProfile(
    name: 'geo',
    rtt: Duration(milliseconds: 650),
    jitter: Duration(milliseconds: 80),
    lossRate: 0.03,
    bandwidthBitsPerSecond: 256000,
  );

  /// LEO (Starlink Maritime): low latency with short regular outages.
  static const NetProfile leo = NetProfile(
    name: 'leo',
    rtt: Duration(milliseconds: 60),
    outageEvery: Duration(minutes: 3),
    outageDuration: Duration(seconds: 5),
  );

  /// Corporate rig network: GEO conditions plus blocked WebSockets and an
  /// aggressive idle cut-off.
  static const NetProfile hostile = NetProfile(
    name: 'hostile',
    rtt: Duration(milliseconds: 650),
    jitter: Duration(milliseconds: 80),
    lossRate: 0.03,
    bandwidthBitsPerSecond: 256000,
    blockWebSocketUpgrade: true,
    idleCutoff: Duration(seconds: 45),
  );

  /// All built-in profiles.
  static const List<NetProfile> all = [geo, leo, hostile];

  /// Looks up a built-in profile by [name], or returns null.
  static NetProfile? byName(String name) {
    for (final profile in all) {
      if (profile.name == name) return profile;
    }
    return null;
  }

  @override
  String toString() => 'NetProfile($name, rtt=${rtt.inMilliseconds}ms)';
}
