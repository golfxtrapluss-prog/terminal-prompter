import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'profiles.dart';

/// Userspace TCP proxy that degrades the link between a client and a target
/// according to a [NetProfile] (docs/07). Used by the `netsim` tests.
///
/// Simulated effects: one-way delay of `rtt / 2` with jitter per chunk
/// (ordering preserved), bandwidth cap, random stalls standing in for packet
/// loss, scheduled and manual outages, idle cut-off, and rejection of
/// WebSocket upgrades.
final class NetSimProxy {
  NetSimProxy._({
    required this.profile,
    required this.targetHost,
    required this.targetPort,
    required ServerSocket server,
    Random? random,
  }) : _server = server,
       _random = random ?? Random();

  /// Starts listening on [listenPort] (0 = ephemeral) and forwarding to
  /// `targetHost:targetPort`.
  static Future<NetSimProxy> start({
    required int targetPort,
    required NetProfile profile,
    String targetHost = '127.0.0.1',
    String listenHost = '127.0.0.1',
    int listenPort = 0,
    Random? random,
  }) async {
    final server = await ServerSocket.bind(listenHost, listenPort);
    final proxy = NetSimProxy._(
      profile: profile,
      targetHost: targetHost,
      targetPort: targetPort,
      server: server,
      random: random,
    );
    server.listen(proxy._accept, onError: (Object _) {});
    proxy._scheduleOutages();
    return proxy;
  }

  /// Conditions applied.
  final NetProfile profile;

  /// Upstream host.
  final String targetHost;

  /// Upstream port.
  final int targetPort;

  final ServerSocket _server;
  final Random _random;
  final Set<_Link> _links = {};
  Timer? _outageTimer;
  bool _online = true;
  bool _stopped = false;

  /// Port clients connect to.
  int get port => _server.port;

  /// Number of client connections currently relayed.
  int get activeConnections => _links.length;

  /// Total bytes relayed in each direction.
  int bytesUp = 0;

  /// Total bytes relayed in each direction.
  int bytesDown = 0;

  /// Whether new connections are accepted and existing ones kept.
  bool get online => _online;

  /// Takes the link down ([online] = false drops every connection and
  /// refuses new ones) or brings it back.
  void setOnline(bool value) {
    _online = value;
    if (!value) cut();
  }

  /// Drops every active connection (clients see a reset/close). New
  /// connections are still accepted while [online].
  void cut() {
    for (final link in _links.toList()) {
      link.close();
    }
  }

  /// Stops listening and drops all connections.
  Future<void> stop() async {
    _stopped = true;
    _outageTimer?.cancel();
    cut();
    await _server.close();
  }

  void _scheduleOutages() {
    final every = profile.outageEvery;
    if (every == null) return;
    _outageTimer = Timer.periodic(every, (_) {
      setOnline(false);
      Timer(profile.outageDuration, () {
        if (!_stopped) setOnline(true);
      });
    });
  }

  Future<void> _accept(Socket client) async {
    if (!_online || _stopped) {
      client.destroy();
      return;
    }
    final Socket upstream;
    try {
      upstream = await Socket.connect(targetHost, targetPort);
    } on SocketException {
      client.destroy();
      return;
    }
    final link = _Link(this, client, upstream);
    _links.add(link);
    unawaited(link.run().whenComplete(() => _links.remove(link)));
  }
}

/// One proxied TCP connection.
final class _Link {
  _Link(this.proxy, this.client, this.upstream);

  final NetSimProxy proxy;
  final Socket client;
  final Socket upstream;
  final Completer<void> _done = Completer<void>();
  Timer? _idleTimer;
  bool _closed = false;
  bool _firstClientChunk = true;

  NetProfile get p => proxy.profile;

  Future<void> run() {
    client.setOption(SocketOption.tcpNoDelay, true);
    upstream.setOption(SocketOption.tcpNoDelay, true);
    _armIdle();
    _pump(client, upstream, up: true);
    _pump(upstream, client, up: false);
    return _done.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _idleTimer?.cancel();
    client.destroy();
    upstream.destroy();
    if (!_done.isCompleted) _done.complete();
  }

  void _armIdle() {
    final idle = p.idleCutoff;
    if (idle == null) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(idle, close);
  }

  /// Forwards [from] to [to] through a delay queue that preserves order.
  void _pump(Socket from, Socket to, {required bool up}) {
    var chain = Future<void>.value();
    var sendAt = DateTime.now();
    from.listen(
      (Uint8List data) {
        if (_closed) return;
        _armIdle();
        if (up && _firstClientChunk) {
          _firstClientChunk = false;
          if (p.blockWebSocketUpgrade && _looksLikeUpgrade(data)) {
            _rejectUpgrade();
            return;
          }
        }
        final delay = _delayFor(data.length);
        // Serialise on a per-direction chain so chunks never overtake.
        final now = DateTime.now();
        sendAt = (sendAt.isAfter(now) ? sendAt : now).add(delay.bandwidth);
        final when = sendAt.add(delay.latency);
        chain = chain.then((_) async {
          final wait = when.difference(DateTime.now());
          if (wait > Duration.zero) await Future<void>.delayed(wait);
          if (_closed) return;
          to.add(data);
          if (up) {
            proxy.bytesUp += data.length;
          } else {
            proxy.bytesDown += data.length;
          }
        });
      },
      onDone: () {
        chain = chain.then((_) async {
          if (_closed) return;
          await to.flush();
          close();
        });
      },
      onError: (Object _) => close(),
      cancelOnError: true,
    );
  }

  ({Duration latency, Duration bandwidth}) _delayFor(int bytes) {
    final rnd = proxy._random;
    var latencyMs = p.rtt.inMilliseconds / 2;
    if (p.jitter > Duration.zero) {
      latencyMs += (rnd.nextDouble() * 2 - 1) * p.jitter.inMilliseconds / 2;
    }
    if (p.lossRate > 0 && rnd.nextDouble() < p.lossRate) {
      // A lost segment costs roughly one retransmission timeout.
      latencyMs += p.rtt.inMilliseconds * 1.5;
    }
    final bps = p.bandwidthBitsPerSecond;
    final bandwidthMs = bps == null ? 0.0 : bytes * 8 * 1000 / bps;
    return (
      latency: Duration(microseconds: (latencyMs * 1000).round()),
      bandwidth: Duration(microseconds: (bandwidthMs * 1000).round()),
    );
  }

  static bool _looksLikeUpgrade(Uint8List data) {
    final head = String.fromCharCodes(data.take(2048)).toLowerCase();
    return head.contains('upgrade: websocket');
  }

  void _rejectUpgrade() {
    const body = 'websocket blocked by proxy';
    client.write(
      'HTTP/1.1 403 Forbidden\r\n'
      'Content-Type: text/plain\r\n'
      'Content-Length: ${body.length}\r\n'
      'Connection: close\r\n\r\n$body',
    );
    unawaited(client.flush().whenComplete(close));
  }
}
