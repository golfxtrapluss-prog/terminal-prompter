import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tp_protocol/tp_protocol.dart';
import 'package:tp_web/src/conn/connection.dart';
import 'package:tp_web/src/conn/transport.dart';

/// Scripted agent on the other side of a fake transport.
final class FakeTransport implements ClientTransport {
  FakeTransport({this.failToOpen = false}) {
    if (failToOpen) {
      Timer.run(() {
        _opened.completeError(StateError('refused'));
        unawaited(_frames.close());
      });
    } else {
      Timer.run(_opened.complete);
    }
  }

  final bool failToOpen;
  final Completer<void> _opened = Completer<void>();
  final StreamController<ServerFrame> _frames = StreamController<ServerFrame>();
  final List<ClientMessage> sentControl = [];
  final List<InputFrame> sentInput = [];
  bool closed = false;

  @override
  int? closeCode;

  @override
  Future<void> get opened => _opened.future;

  @override
  Stream<ServerFrame> get frames => _frames.stream;

  @override
  bool get isOpen => _opened.isCompleted && !closed && !failToOpen;

  @override
  void sendText(String text) => sentControl.add(decodeClientMessage(text));

  @override
  void sendBinary(Uint8List bytes) =>
      sentInput.add(decodeBinaryFrame(bytes) as InputFrame);

  @override
  void close() {
    if (closed) return;
    closed = true;
    unawaited(_frames.close());
  }

  /// Agent -> client.
  void reply(ServerMessage m) => _frames.add(TextServerFrame(encodeMessage(m)));
  void output(SessionId s, int seq, String text) => _frames.add(
    BinaryServerFrame(encodeOutputFrame(s, seq, utf8.encode(text))),
  );

  /// Drops the connection from the agent side.
  void dropFromServer() => close();

  Future<T> expectControl<T extends ClientMessage>() async {
    for (var i = 0; i < 200; i++) {
      final idx = sentControl.indexWhere((m) => m is T);
      if (idx >= 0) return sentControl.removeAt(idx) as T;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException(
      'client never sent $T; sent=${sentControl.map((m) => m.type)}',
    );
  }
}

final class FakeTerminal implements TerminalSink {
  final StringBuffer text = StringBuffer();
  final List<String> notices = [];
  int clears = 0;

  @override
  (int, int) get size => (80, 24);

  final List<bool> replayFlags = [];

  @override
  void writeOutput(Uint8List data, {bool replay = false}) {
    replayFlags.add(replay);
    text.write(utf8.decode(data));
  }

  @override
  void writeNotice(String t) => notices.add(t);

  @override
  void clearAll() => clears++;
}

void main() {
  final sid = SessionId.random(Random(5));
  late FakeTerminal terminal;
  late List<FakeTransport> transports;
  late MemoryStore store;
  late Connection conn;
  late List<ConnState> states;

  Connection make({
    bool Function()? failNext,
    Duration deadAfter = const Duration(seconds: 5),
  }) {
    transports = [];
    terminal = FakeTerminal();
    store = MemoryStore();
    states = [];
    final c = Connection(
      terminal: terminal,
      wsUrl: 'ws://agent.test/api/ws',
      transportFactory: (_) {
        final t = FakeTransport(failToOpen: failNext?.call() ?? false);
        transports.add(t);
        return t;
      },
      clientId: 'test',
      store: store,
      backoff: Backoff(random: Random(1), scale: 0.01),
      heartbeat: const Duration(milliseconds: 40),
      deadAfter: deadAfter,
      random: Random(9),
    );
    c.states.listen(states.add);
    return c;
  }

  /// Plays the agent side of a successful handshake on the newest transport.
  Future<Attach> handshake({SessionId? session, int seq = 0}) async {
    final t = transports.last;
    final hello = await t.expectControl<ClientHello>();
    expect(hello.instance, conn.instanceId);
    t.reply(ServerHello(version: protocolVersion, agent: 'a', host: 'h'));
    final attach = await t.expectControl<Attach>();
    t.reply(
      Attached(
        session: session ?? sid,
        name: 'one',
        seq: seq,
        cols: 80,
        rows: 24,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return attach;
  }

  tearDown(() => conn.stop());

  test('connects, attaches a new session, writes output and acks', () async {
    conn = make()..start();
    final attach = await handshake();
    expect(attach.session, isNull);
    expect(conn.state, isA<Live>());
    expect(store.read('tp.session'), sid.toString());
    expect(terminal.clears, 1);

    final t = transports.single;
    t.output(sid, 0, 'hello ');
    t.output(sid, 6, 'world');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(terminal.text.toString(), 'hello world');
    expect(conn.lastSeq, 11);
    final ack = await t.expectControl<Ack>();
    expect(ack.seq, 11);
  });

  test(
    'reconnects with backoff after a drop and resumes from last_seq',
    () async {
      conn = make()..start();
      await handshake();
      transports.single.output(sid, 0, 'abc');
      await Future<void>.delayed(const Duration(milliseconds: 5));

      transports.single.dropFromServer();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(states.whereType<Disconnected>().first.reason, 'connection lost');
      expect(transports, hasLength(2));

      final attach = await handshake(seq: 3);
      expect(attach.session, sid);
      expect(attach.lastSeq, 3);
      expect(terminal.clears, 1, reason: 'no clear on resume');

      // Overlapping replay is trimmed.
      transports.last.output(sid, 1, 'bcdef');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(terminal.text.toString(), 'abcdef');
    },
  );

  test('backoff grows across failed attempts and resets when live', () async {
    var failures = 0;
    conn = make(failNext: () => failures++ < 3)..start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final delays = states
        .whereType<Disconnected>()
        .map((s) => s.retryIn!.inMilliseconds)
        .toList();
    expect(delays, hasLength(greaterThanOrEqualTo(3)));
    expect(delays[1], greaterThan(delays[0]));
    expect(delays[2], greaterThan(delays[1]));
    expect(states.whereType<Disconnected>().first.reason, 'cannot reach agent');
    await handshake();
    expect(conn.state, isA<Live>());
  });

  test('unacked input is resent after reconnect with the same ids', () async {
    conn = make()..start();
    await handshake();
    conn.sendInput(Connection.encodeInput('ls\r'));
    conn.sendInput(Connection.encodeInput('pwd\r'));
    final first = transports.single;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(first.sentInput.map((f) => f.clientMsgId), [1, 2]);
    first.reply(AckIn(session: sid, id: 1));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(conn.pendingInput, 1);

    first.dropFromServer();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await handshake();
    final second = transports.last;
    expect(second.sentInput.map((f) => f.clientMsgId), [2]);
    expect(utf8.decode(second.sentInput.single.data), 'pwd\r');
  });

  test('stale stored session falls back to a new one', () async {
    conn = make();
    store.write('tp.session', sid.toString());
    conn.start();
    final t = transports.single;
    await t.expectControl<ClientHello>();
    t.reply(ServerHello(version: protocolVersion, agent: 'a', host: 'h'));
    final attach = await t.expectControl<Attach>();
    expect(attach.session, sid);
    t.reply(
      ErrorMessage(code: ErrorCode.sessionNotFound, msg: 'gone', session: sid),
    );
    final retry = await t.expectControl<Attach>();
    expect(retry.session, isNull);
  });

  test('silent connection is closed by the heartbeat watchdog', () async {
    conn = make(deadAfter: const Duration(milliseconds: 100))..start();
    await handshake();
    final t = transports.single;
    await t.expectControl<Ping>();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(t.closed, isTrue, reason: 'no traffic for longer than deadAfter');
    expect(transports.length, greaterThan(1), reason: 'reconnect scheduled');
  });

  test('notifyOnline retries immediately while disconnected', () async {
    conn = make()..start();
    await handshake();
    transports.single.dropFromServer();
    await Future<void>.delayed(const Duration(milliseconds: 2));
    expect(conn.state, isA<Disconnected>());
    conn.notifyOnline();
    expect(transports, hasLength(2));
  });

  test(
    'session exit forgets the session and new session attaches null',
    () async {
      conn = make()..start();
      await handshake();
      transports.single.reply(
        SessionExit(session: sid, status: const ExitStatus(code: 0)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(store.read('tp.session'), isNull);
      expect(terminal.notices.single, contains('session ended'));
      conn.newSession();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final attach = await handshake();
      expect(attach.session, isNull);
    },
  );

  test(
    'output before attached.seq is flagged as replay, later output is live',
    () async {
      conn = make()..start();
      await handshake(seq: 6);
      final t = transports.single;
      t.output(sid, 0, 'replay');
      t.output(sid, 6, 'live');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(terminal.text.toString(), 'replaylive');
      expect(terminal.replayFlags, [true, false]);
    },
  );
}
