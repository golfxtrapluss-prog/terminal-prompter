@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tp_netsim/tp_netsim.dart';

/// Echo server used as the upstream.
Future<ServerSocket> echoServer() async {
  final server = await ServerSocket.bind('127.0.0.1', 0);
  server.listen((socket) {
    socket.listen(socket.add, onDone: socket.destroy, onError: (Object _) {});
  });
  return server;
}

Future<String> roundTrip(
  int port,
  String text, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  socket.write(text);
  final reply = await socket.map(utf8.decode).first.timeout(timeout);
  socket.destroy();
  return reply;
}

void main() {
  late ServerSocket echo;
  setUp(() async => echo = await echoServer());
  tearDown(() => echo.close());

  test('adds the profile round-trip time', () async {
    final proxy = await NetSimProxy.start(
      targetPort: echo.port,
      profile: const NetProfile(name: 't', rtt: Duration(milliseconds: 300)),
    );
    final sw = Stopwatch()..start();
    expect(await roundTrip(proxy.port, 'hi'), 'hi');
    expect(sw.elapsedMilliseconds, inInclusiveRange(250, 1500));
    expect(proxy.bytesUp, 2);
    expect(proxy.bytesDown, 2);
    await proxy.stop();
  });

  test('bandwidth cap stretches large transfers', () async {
    final proxy = await NetSimProxy.start(
      targetPort: echo.port,
      profile: const NetProfile(
        name: 'slow',
        rtt: Duration.zero,
        bandwidthBitsPerSecond: 80000,
      ),
    );
    final socket = await Socket.connect('127.0.0.1', proxy.port);
    final payload = List.filled(10000, 0x61); // 80 kbit -> ~1 s each way
    final sw = Stopwatch()..start();
    socket.add(payload);
    var received = 0;
    await for (final chunk in socket) {
      received += chunk.length;
      if (received >= payload.length) break;
    }
    expect(sw.elapsedMilliseconds, greaterThan(1500));
    socket.destroy();
    await proxy.stop();
  });

  test('cut drops connections and setOnline(false) refuses new ones', () async {
    final proxy = await NetSimProxy.start(
      targetPort: echo.port,
      profile: const NetProfile(name: 'ok', rtt: Duration.zero),
    );
    final socket = await Socket.connect('127.0.0.1', proxy.port);
    final closed = Completer<void>();
    socket.listen((_) {}, onDone: closed.complete, onError: (Object _) {});
    socket.write('a');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(proxy.activeConnections, 1);
    proxy.cut();
    await closed.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(proxy.activeConnections, 0);

    proxy.setOnline(false);
    final refused = await Socket.connect('127.0.0.1', proxy.port);
    final refusedClosed = Completer<void>();
    refused.listen(
      (_) {},
      onDone: refusedClosed.complete,
      onError: (Object _) {},
    );
    await refusedClosed.future.timeout(const Duration(seconds: 5));
    refused.destroy();
    proxy.setOnline(true);
    expect(await roundTrip(proxy.port, 'back'), 'back');
    await proxy.stop();
  });

  test(
    'idle cut-off closes silent connections, traffic keeps them alive',
    () async {
      final proxy = await NetSimProxy.start(
        targetPort: echo.port,
        profile: const NetProfile(
          name: 'idle',
          rtt: Duration.zero,
          idleCutoff: Duration(milliseconds: 400),
        ),
      );
      final busy = await Socket.connect('127.0.0.1', proxy.port);
      final idle = await Socket.connect('127.0.0.1', proxy.port);
      var busyClosed = false;
      var idleClosed = false;
      busy.listen(
        (_) {},
        onDone: () => busyClosed = true,
        onError: (Object _) {},
      );
      idle.listen(
        (_) {},
        onDone: () => idleClosed = true,
        onError: (Object _) {},
      );
      for (var i = 0; i < 6; i++) {
        busy.write('x');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(busyClosed, isFalse);
      expect(idleClosed, isTrue);
      busy.destroy();
      await proxy.stop();
    },
  );

  test('blocks WebSocket upgrades with 403 but passes plain HTTP', () async {
    final proxy = await NetSimProxy.start(
      targetPort: echo.port,
      profile: const NetProfile(
        name: 'nows',
        rtt: Duration.zero,
        blockWebSocketUpgrade: true,
      ),
    );
    final upgrade = await roundTrip(
      proxy.port,
      'GET /api/ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n',
    );
    expect(upgrade, startsWith('HTTP/1.1 403'));
    final plain = await roundTrip(
      proxy.port,
      'GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n',
    );
    expect(plain, startsWith('GET /healthz'));
    await proxy.stop();
  });

  test('scheduled outages take the link down and up', () async {
    final proxy = await NetSimProxy.start(
      targetPort: echo.port,
      profile: const NetProfile(
        name: 'flap',
        rtt: Duration.zero,
        outageEvery: Duration(milliseconds: 300),
        outageDuration: Duration(milliseconds: 150),
      ),
    );
    final seen = <bool>{};
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 1200) {
      seen.add(proxy.online);
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(seen, {true, false});
    await proxy.stop();
  });
}
