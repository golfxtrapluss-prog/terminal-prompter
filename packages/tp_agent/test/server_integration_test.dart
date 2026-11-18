@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:tp_agent/src/log.dart';
import 'package:tp_agent/tp_agent.dart';
import 'package:tp_protocol/tp_protocol.dart';

import 'support/sse_client.dart';

const _config = r'''
listen = "127.0.0.1:1"

[shell]
command = "/bin/bash"
args = ["--norc", "--noprofile", "-i"]
env = { TERM = "xterm-256color", PS1 = "TP$ ", LANG = "C.UTF-8" }

[sessions]
max = 2
scrollback_bytes = 65536

[transport]
output_coalesce = "5ms"
''';

/// Test client over a dart:io WebSocket with a pollable inbox.
final class TestClient {
  TestClient(this.socket) {
    socket.listen((Object? event) {
      if (event is String) {
        inbox.add(decodeServerMessage(event));
      } else if (event is List<int>) {
        final frame = decodeBinaryFrame(Uint8List.fromList(event));
        if (frame is OutputFrame) {
          output.write(latin1.decode(frame.data));
          lastSeq = frame.seq + frame.data.length;
          frames.add(frame);
        }
      }
    }, onDone: () => closed = true);
  }

  static Future<TestClient> connect(int port) async =>
      TestClient(await WebSocket.connect('ws://127.0.0.1:$port/api/ws'));

  final WebSocket socket;
  final List<ServerMessage> inbox = [];
  final List<OutputFrame> frames = [];
  final StringBuffer output = StringBuffer();
  int lastSeq = 0;
  int nextId = 1;
  bool closed = false;

  void send(ClientMessage m) => socket.add(encodeMessage(m));

  int sendInput(SessionId session, String text) {
    final id = nextId++;
    socket.add(encodeInputFrame(session, id, utf8.encode(text)));
    return id;
  }

  Future<T> next<T extends ServerMessage>({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final sw = Stopwatch()..start();
    while (true) {
      final i = inbox.indexWhere((m) => m is T);
      if (i >= 0) return inbox.removeAt(i) as T;
      if (closed) throw StateError('closed while waiting for $T; inbox=$inbox');
      if (sw.elapsed > timeout) {
        throw TimeoutException('no $T; inbox=${inbox.map((m) => m.type)}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> waitOutput(
    String needle, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final sw = Stopwatch()..start();
    while (!output.toString().contains(needle)) {
      if (closed) throw StateError('closed before "$needle": $output');
      if (sw.elapsed > timeout) {
        throw TimeoutException('no "$needle" in output: $output');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<Attached> hello({SessionId? session, int? lastSeq}) async {
    send(const ClientHello(version: protocolVersion, client: 'test'));
    await next<ServerHello>();
    send(Attach(session: session, cols: 80, rows: 24, lastSeq: lastSeq));
    return next<Attached>();
  }

  Future<void> close() => socket.close();
}

void main() {
  late Directory webDir;
  late SessionManager sessions;
  late AgentServer server;
  late Uri base;

  setUpAll(() async {
    installJsonLogging(level: Level.ALL);
    webDir = await Directory.systemTemp.createTemp('tp_web_');
    await File('${webDir.path}/index.html').writeAsString('<title>tp</title>');
    final config = AgentConfig.parse(_config);
    sessions = SessionManager(config: config);
    server = AgentServer(
      config: config,
      sessions: sessions,
      staticFiles: DirectoryStaticFiles(webDir.path),
      auth: null,
      agentVersion: 'test',
      port: 0,
    );
    await server.start();
    base = Uri.parse('http://127.0.0.1:${server.port}/');
  });

  tearDownAll(() async {
    await server.stop();
    await sessions.shutdown();
    await webDir.delete(recursive: true);
  });

  group('http', () {
    final http = HttpClient();

    Future<HttpClientResponse> get(String path) async =>
        (await http.getUrl(base.resolve(path))).close();

    test('healthz, index and 404 with security headers', () async {
      final health = await get('healthz');
      expect(health.statusCode, 200);
      expect(await utf8.decodeStream(health), 'ok');
      expect(
        health.headers.value('content-security-policy'),
        contains("default-src 'self'"),
      );
      expect(health.headers.value('x-frame-options'), 'DENY');
      expect(health.headers.value('server'), isNull);

      final index = await get('');
      expect(index.statusCode, 200);
      expect(index.headers.contentType?.mimeType, 'text/html');
      expect(await utf8.decodeStream(index), contains('<title>tp</title>'));

      final missing = await get('nope.txt');
      expect(missing.statusCode, 404);
      await missing.drain<void>();

      final api = await get('api/nothing');
      expect(api.statusCode, 404);
      expect(api.headers.value('cache-control'), 'no-store');
      await api.drain<void>();

      final traversal = await get('..%2F..%2Fetc%2Fpasswd');
      expect(traversal.statusCode, 404);
      await traversal.drain<void>();
    });
  });

  group('websocket', () {
    test('hello, attach, input with ack_in, output, resize, list', () async {
      final c = await TestClient.connect(server.port);
      c.send(const ClientHello(version: protocolVersion, client: 'test'));
      final hello = await c.next<ServerHello>();
      expect(hello.version, protocolVersion);
      expect(hello.caps, containsAll([Caps.binary, Caps.ackIn]));
      expect(hello.agent, 'test');

      c.send(const Attach(name: 'first', cols: 80, rows: 24));
      final attached = await c.next<Attached>();
      expect(attached.name, 'first');
      expect(attached.cols, 80);
      await c.waitOutput(r'TP$ ');

      final id = c.sendInput(attached.session, "printf 'tp-%s\\n' ok\r");
      final ack = await c.next<AckIn>();
      expect(ack.id, id);
      expect(ack.session, attached.session);
      await c.waitOutput('tp-ok');

      c.send(Resize(session: attached.session, cols: 100, rows: 40));
      c.sendInput(attached.session, 'stty size\r');
      await c.waitOutput('40 100');

      c.send(const ListSessions());
      final list = await c.next<SessionsMessage>();
      final mine = list.sessions.singleWhere((s) => s.id == attached.session);
      expect(mine.clients, 1);
      expect(mine.exited, isNull);

      // Frames carry contiguous sequence numbers.
      var expected = c.frames.first.seq;
      for (final f in c.frames) {
        expect(f.seq, expected);
        expected += f.data.length;
      }

      await c.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sessions.get(attached.session)!.clients, 0);
      await sessions.kill(attached.session);
    });

    test(
      'a second client resumes from last_seq or replays scrollback',
      () async {
        final a = await TestClient.connect(server.port);
        final attached = await a.hello();
        await a.waitOutput(r'TP$ ');
        a.sendInput(attached.session, 'echo marker-one\r');
        await a.waitOutput('marker-one\r\n');
        final seqAfterOne = a.lastSeq;

        // Full replay: a fresh client sees the whole scrollback.
        final b = await TestClient.connect(server.port);
        final attachedB = await b.hello(session: attached.session);
        expect(attachedB.session, attached.session);
        expect(attachedB.truncated, isNull);
        await b.waitOutput('marker-one');

        // Resume: a client that already has everything gets only new output.
        a.sendInput(attached.session, 'echo marker-two\r');
        await a.waitOutput('marker-two\r\n');
        final c = await TestClient.connect(server.port);
        await c.hello(session: attached.session, lastSeq: seqAfterOne);
        await c.waitOutput('marker-two');
        expect(c.output.toString(), isNot(contains('marker-one\r\n')));
        expect(c.frames.first.seq, seqAfterOne);

        // Kill: every attached client is told, the list is empty afterwards.
        c.send(KillSession(attached.session));
        final exitA = await a.next<SessionExit>();
        expect(exitA.session, attached.session);
        final list = await c.next<SessionsMessage>();
        expect(list.sessions.where((s) => s.id == attached.session), isEmpty);

        await a.close();
        await b.close();
        await c.close();
      },
    );

    test('truncated replay when scrollback was overwritten', () async {
      final a = await TestClient.connect(server.port);
      final attached = await a.hello();
      await a.waitOutput(r'TP$ ');
      // 65536-byte buffer; produce ~200 KB of output.
      a.sendInput(attached.session, 'seq 1 40000; echo done-big\r');
      await a.waitOutput('done-big', timeout: const Duration(seconds: 30));

      final b = await TestClient.connect(server.port);
      final attachedB = await b.hello(session: attached.session, lastSeq: 0);
      expect(attachedB.truncated, isNotNull);
      expect(attachedB.truncated!.from, 0);
      expect(attachedB.truncated!.to, greaterThan(0));
      await b.waitOutput('done-big');
      expect(b.frames.first.seq, attachedB.truncated!.to);

      await sessions.kill(attached.session);
      await a.close();
      await b.close();
    });

    test(
      'errors: message before hello, unknown session, bad json, limit',
      () async {
        final c = await TestClient.connect(server.port);
        c.send(const ListSessions());
        var error = await c.next<ErrorMessage>();
        expect(error.code, ErrorCode.badMessage);

        c.send(const ClientHello(version: protocolVersion, client: 'test'));
        await c.next<ServerHello>();

        c.send(Detach(SessionId.random()));
        error = await c.next<ErrorMessage>();
        expect(error.code, ErrorCode.sessionNotFound);

        c.socket.add('{not json');
        error = await c.next<ErrorMessage>();
        expect(error.code, ErrorCode.badMessage);

        c.socket.add(encodeOutputFrame(SessionId.random(), 0, const [1]));
        error = await c.next<ErrorMessage>();
        expect(error.code, ErrorCode.badMessage);

        final first = await (await TestClient.connect(server.port)).hello();
        final second = await (await TestClient.connect(server.port)).hello();
        c.send(const Attach(cols: 80, rows: 24));
        error = await c.next<ErrorMessage>();
        expect(error.code, ErrorCode.sessionLimit);

        await sessions.kill(first.session);
        await sessions.kill(second.session);
        await c.close();
      },
    );

    test('version mismatch closes the connection', () async {
      final c = await TestClient.connect(server.port);
      c.send(const ClientHello(version: 99, client: 'future'));
      final error = await c.next<ErrorMessage>();
      expect(error.code, ErrorCode.versionMismatch);
      await c.socket.done.timeout(const Duration(seconds: 5));
      expect(c.closed, isTrue);
    });
  });

  group('sse fallback', () {
    test(
      'hello, attach, input with ack_in, output, resume and session list',
      () async {
        final c = SseTestClient(base);
        await c.connect();
        expect(c.stream, isNotNull);
        expect(
          await c.send(
            const ClientHello(version: protocolVersion, client: 'sse-test'),
          ),
          204,
        );
        await c.next<ServerHello>();
        await c.send(const Attach(name: 'via-sse', cols: 80, rows: 24));
        final attached = await c.next<Attached>();
        expect(attached.name, 'via-sse');
        await c.waitOutput(r'TP$ ');

        await c.input(
          attached.session,
          'echo over-sse\r',
          id: 5,
          prompter: true,
        );
        expect((await c.next<AckIn>()).id, 5);
        await c.waitOutput('over-sse\r\n');
        final seqAfter = c.lastSeq!;

        // A second stream resumes with last_seq and sees only new output.
        final d = SseTestClient(base);
        await d.connect();
        await d.send(
          const ClientHello(version: protocolVersion, client: 'sse-test'),
        );
        await d.next<ServerHello>();
        d.lastSeq = seqAfter;
        await d.send(
          Attach(
            session: attached.session,
            cols: 80,
            rows: 24,
            lastSeq: seqAfter,
          ),
        );
        await d.next<Attached>();
        await d.input(attached.session, 'echo second\r');
        await d.waitOutput('second\r\n');
        expect(d.output.toString(), isNot(contains('over-sse\r\n')));

        // Unknown stream ids and malformed bodies are refused.
        final bad = SseTestClient(base)..stream = 'nope';
        expect(await bad.send(const ListSessions()), 404);
        expect(await c.post(['not an object']), 400);

        await sessions.kill(attached.session);
        await c.close();
        await d.close();
        await bad.close();
      },
    );
  });
}
