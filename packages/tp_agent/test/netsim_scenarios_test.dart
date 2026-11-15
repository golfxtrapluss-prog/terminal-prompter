@Tags(['netsim'])
@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tp_agent/tp_agent.dart';
import 'package:tp_netsim/tp_netsim.dart';
import 'package:tp_protocol/tp_protocol.dart';

/// Scenarios 1-6 from docs/11 through the tp_netsim proxy with the geo and
/// leo profiles. Scenario 5 (WebSocket blocked -> SSE) needs the SSE
/// transport from M6 and is marked skipped until then.
const _config = r'''
listen = "127.0.0.1:1"

[shell]
command = "/bin/bash"
args = ["--norc", "--noprofile", "-i"]
env = { TERM = "xterm-256color", PS1 = "TP$ ", LANG = "C.UTF-8" }

[sessions]
max = 4
scrollback_bytes = 65536

[transport]
output_coalesce = "5ms"
heartbeat = "2s"
''';

/// Minimal resuming client: the same resume rules as the web client
/// (attach with `last_seq`, drop overlapping bytes, resend unacked input).
final class ResumingClient {
  ResumingClient(this.port, {required this.instance});

  final int port;
  final String instance;
  final StringBuffer output = StringBuffer();
  final List<ServerMessage> inbox = [];
  final List<OutputFrame> frames = [];
  final Map<int, Uint8List> unackedInput = {};
  WebSocket? socket;
  SessionId? session;
  int? lastSeq;
  int nextId = 1;
  int connections = 0;
  bool acks = true;
  bool closed = true;

  Future<Attached> connect({bool newSession = false}) async {
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:$port/api/ws',
    ).timeout(const Duration(seconds: 20));
    socket = ws;
    closed = false;
    connections++;
    ws.listen(_onEvent, onDone: () => closed = true, onError: (Object _) {});
    unawaited(
      ws.done.then((_) {}, onError: (Object _) {}),
    ); // writes after a cut
    ws.add(
      encodeMessage(
        ClientHello(
          version: protocolVersion,
          client: 'netsim-test',
          instance: instance,
        ),
      ),
    );
    await next<ServerHello>();
    ws.add(
      encodeMessage(
        Attach(
          session: newSession ? null : session,
          cols: 80,
          rows: 24,
          lastSeq: newSession ? null : lastSeq,
        ),
      ),
    );
    final attached = await next<Attached>();
    session = attached.session;
    for (final entry in unackedInput.entries) {
      ws.add(encodeInputFrame(session!, entry.key, entry.value));
    }
    return attached;
  }

  void _onEvent(Object? event) {
    if (event is String) {
      final m = decodeServerMessage(event);
      if (m is AckIn) unackedInput.remove(m.id);
      inbox.add(m);
      return;
    }
    if (event is! List<int>) return;
    final frame = decodeBinaryFrame(Uint8List.fromList(event));
    if (frame is! OutputFrame) return;
    var data = frame.data;
    var seq = frame.seq;
    final expected = lastSeq;
    if (expected != null && seq < expected) {
      final skip = expected - seq;
      if (skip >= data.length) return;
      data = Uint8List.sublistView(data, skip);
      seq = expected;
    }
    output.write(latin1.decode(data));
    lastSeq = seq + data.length;
    frames.add(OutputFrame(session: frame.session, seq: seq, data: data));
    if (acks) {
      socket?.add(encodeMessage(Ack(session: frame.session, seq: lastSeq!)));
    }
  }

  int sendInput(String text, {int? id}) {
    final msgId = id ?? nextId++;
    final bytes = utf8.encode(text);
    unackedInput[msgId] = bytes;
    socket?.add(encodeInputFrame(session!, msgId, bytes));
    return msgId;
  }

  Future<T> next<T extends ServerMessage>({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final sw = Stopwatch()..start();
    while (true) {
      final i = inbox.indexWhere((m) => m is T);
      if (i >= 0) return inbox.removeAt(i) as T;
      if (closed) throw StateError('closed while waiting for $T');
      if (sw.elapsed > timeout) throw TimeoutException('no $T');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> waitOutput(
    String needle, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final sw = Stopwatch()..start();
    while (!output.toString().contains(needle)) {
      if (sw.elapsed > timeout) {
        throw TimeoutException('no "$needle"; tail: ${_tail()}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<void> waitClosed({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final sw = Stopwatch()..start();
    while (!closed) {
      if (sw.elapsed > timeout) throw TimeoutException('socket still open');
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  String _tail() {
    final s = output.toString();
    return s.length > 300 ? s.substring(s.length - 300) : s;
  }

  Future<void> close() async => socket?.close();
}

void main() {
  late SessionManager sessions;
  late AgentServer server;
  late Directory webDir;

  setUpAll(() async {
    webDir = await Directory.systemTemp.createTemp('tp_netsim_');
    final config = AgentConfig.parse(_config);
    sessions = SessionManager(config: config);
    server = AgentServer(
      config: config,
      sessions: sessions,
      staticFiles: DirectoryStaticFiles(webDir.path),
      agentVersion: 'netsim',
      port: 0,
    );
    await server.start();
  });

  tearDownAll(() async {
    await server.stop();
    await sessions.shutdown();
    await webDir.delete(recursive: true);
  });

  for (final profile in [NetProfile.geo, NetProfile.leo]) {
    group('profile ${profile.name}', () {
      late NetSimProxy proxy;
      setUp(() async {
        proxy = await NetSimProxy.start(
          targetPort: server.port,
          profile: profile.withoutOutages(),
        );
      });
      tearDown(() => proxy.stop());

      test('1. resume without loss or duplicates across a cut', () async {
        final c = ResumingClient(proxy.port, instance: 's1-${profile.name}');
        await c.connect(newSession: true);
        await c.waitOutput(r'TP$ ');
        const n = 6000;
        c.sendInput('seq 1 $n; echo END-S1\r');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        proxy.cut();
        await c.waitClosed();
        await c.connect();
        await c.waitOutput('END-S1', timeout: const Duration(seconds: 120));
        expect(c.connections, 2);

        final numbers = RegExp(r'^(\d+)\r?$', multiLine: true)
            .allMatches(c.output.toString().split('seq 1 $n').last)
            .map((m) => int.parse(m.group(1)!))
            .toList();
        expect(numbers.length, n, reason: 'every line exactly once');
        expect(numbers, List.generate(n, (i) => i + 1));
        await sessions.kill(c.session!);
      });

      test(
        '2. duplicate client_msg_id is written once, also across a cut',
        () async {
          final c = ResumingClient(proxy.port, instance: 's2-${profile.name}');
          await c.connect(newSession: true);
          await c.waitOutput(r'TP$ ');
          final f =
              '/tmp/tp-idem-${profile.name}-${DateTime.now().microsecondsSinceEpoch}';
          final id = c.sendInput('echo X >> $f\r');
          await c.next<AckIn>();
          c.sendInput('echo X >> $f\r', id: id); // plain resend
          await c.next<AckIn>();
          // Resend after reconnect: pretend the ack was lost.
          c.unackedInput[id] = utf8.encode('echo X >> $f\r');
          proxy.cut();
          await c.waitClosed();
          await c.connect();
          await c.next<AckIn>();
          c.sendInput('wc -l < $f; echo END-S2\r');
          await c.waitOutput('END-S2');
          final transcript = c.output.toString();
          expect(
            transcript,
            contains('\r1\r\nEND-S2'),
            reason: 'file has one line',
          );
          expect(
            'echo X >> '.allMatches(transcript).length,
            1,
            reason: 'the resent command was not executed again',
          );
          await sessions.kill(c.session!);
          await File(f).delete();
        },
      );

      test(
        '3. truncated replay after producing more than the scrollback offline',
        () async {
          final c = ResumingClient(proxy.port, instance: 's3-${profile.name}');
          await c.connect(newSession: true);
          await c.waitOutput(r'TP$ ');
          c.sendInput('sleep 1; seq 1 30000; echo END-S3\r');
          await c.next<AckIn>();
          proxy.cut();
          await c.waitClosed();
          await Future<void>.delayed(const Duration(seconds: 4));
          final attached = await c.connect();
          expect(attached.truncated, isNotNull);
          expect(attached.truncated!.to, greaterThan(attached.truncated!.from));
          await c.waitOutput('END-S3', timeout: const Duration(seconds: 120));
          await sessions.kill(c.session!);
        },
      );

      test('4. slow client is paused, then dropped, and can resume', () async {
        final c = ResumingClient(proxy.port, instance: 's4-${profile.name}')
          ..acks = false;
        await c.connect(newSession: true);
        await c.waitOutput(r'TP$ ');
        final rssBefore = ProcessInfo.currentRss;
        // ~20 MB of output while the client never acknowledges.
        c.sendInput('yes | head -c 20000000; echo END-S4\r');
        await c.waitClosed(timeout: const Duration(seconds: 120));
        final rssAfter = ProcessInfo.currentRss;
        expect(
          rssAfter - rssBefore,
          lessThan(40 * 1024 * 1024),
          reason: 'agent memory bounded',
        );
        c.acks = true;
        final attached = await c.connect();
        expect(attached.truncated, isNotNull);
        await c.waitOutput('END-S4', timeout: const Duration(seconds: 120));
        await sessions.kill(c.session!);
      });

      test(
        '6. heartbeat keeps the connection alive through an idle cut-off',
        () async {
          await proxy.stop();
          proxy = await NetSimProxy.start(
            targetPort: server.port,
            profile: NetProfile(
              name: 'idle',
              rtt: profile.rtt,
              idleCutoff: const Duration(seconds: 5),
            ),
          );
          final c = ResumingClient(proxy.port, instance: 's6-${profile.name}');
          await c.connect(newSession: true);
          await c.waitOutput(r'TP$ ');
          await Future<void>.delayed(const Duration(seconds: 6));
          expect(
            c.closed,
            isFalse,
            reason: 'ping frames every 500 ms must reset the idle timer',
          );
          c.sendInput('echo END-S6\r');
          await c.waitOutput('END-S6');
          await sessions.kill(c.session!);
        },
      );
    });
  }

  test(
    '5. WebSocket blocked -> SSE fallback',
    () {},
    skip: 'needs the SSE transport (M6)',
  );
}

extension on NetProfile {
  /// Same profile without scheduled outages, so tests control the cuts.
  NetProfile withoutOutages() => NetProfile(
    name: name,
    rtt: rtt,
    jitter: jitter,
    lossRate: lossRate,
    bandwidthBitsPerSecond: bandwidthBitsPerSecond,
    blockWebSocketUpgrade: blockWebSocketUpgrade,
    idleCutoff: idleCutoff,
  );
}
