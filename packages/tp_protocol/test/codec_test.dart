import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tp_protocol/tp_protocol.dart';

void main() {
  final sid = SessionId.random(Random(3));
  final info = SessionInfo(
    id: sid,
    name: 'coolify',
    created: DateTime.utc(2026, 11, 14, 12),
    lastSeen: DateTime.utc(2026, 11, 14, 13, 30),
    clients: 2,
    exited: const ExitStatus(signal: 9),
  );

  Object? canonical(ProtocolMessage m) => jsonDecode(encodeMessage(m));

  group('client messages round-trip', () {
    final messages = <ClientMessage>[
      const ClientHello(version: 1, client: 'tp_web/0.1', caps: ['binary']),
      Attach(session: sid, cols: 80, rows: 24, lastSeq: 1234),
      const Attach(session: null, name: 'new', cols: 120, rows: 40),
      Detach(sid),
      Resize(session: sid, cols: 100, rows: 30),
      SignalMessage(session: sid, signal: TerminalSignal.interrupt),
      Ack(session: sid, seq: 99),
      KillSession(sid),
      Rename(session: sid, name: 'prod'),
      const ListSessions(),
      const Ping(1700000000000),
    ];
    for (final m in messages) {
      test(m.type, () {
        final text = encodeMessage(m);
        final back = decodeClientMessage(text);
        expect(back.runtimeType, m.runtimeType);
        expect(canonical(back), canonical(m));
      });
    }
  });

  group('server messages round-trip', () {
    final messages = <ServerMessage>[
      ServerHello(
        version: 1,
        agent: 'tp-agent/0.1',
        host: 'vps1',
        caps: const ['binary', 'ack_in'],
        sessions: [info],
      ),
      Attached(session: sid, name: 'x', seq: 5000, cols: 80, rows: 24),
      Attached(
        session: sid,
        name: 'x',
        seq: 5000,
        cols: 80,
        rows: 24,
        truncated: (from: 10, to: 4000),
      ),
      SessionsMessage([info]),
      SessionExit(session: sid, status: const ExitStatus(code: 0)),
      SessionExit(session: sid, status: const ExitStatus(signal: 15)),
      const Pong(42),
      AckIn(session: sid, id: 7),
      ErrorMessage(code: ErrorCode.sessionNotFound, msg: 'gone', session: sid),
      const ErrorMessage(code: ErrorCode.badMessage, msg: 'nope'),
      const Notice(level: 'info', msg: 'updated'),
    ];
    for (final m in messages) {
      test(m.type, () {
        final text = encodeMessage(m);
        final back = decodeServerMessage(text);
        expect(back.runtimeType, m.runtimeType);
        expect(canonical(back), canonical(m));
      });
    }
  });

  test('attached decodes truncation and session info fields', () {
    final hello =
        decodeServerMessage(
              encodeMessage(
                ServerHello(
                  version: 1,
                  agent: 'a',
                  host: 'h',
                  sessions: [info],
                ),
              ),
            )
            as ServerHello;
    final s = hello.sessions.single;
    expect(s.id, sid);
    expect(s.created, info.created);
    expect(s.lastSeen, info.lastSeen);
    expect(s.clients, 2);
    expect(s.exited?.signal, 9);
    expect(s.exited?.code, isNull);

    final att =
        decodeServerMessage(
              '{"t":"attached","session":"$sid","name":"n","seq":9,"cols":1,"rows":1,'
              '"truncated":{"from":1,"to":5}}',
            )
            as Attached;
    expect(att.truncated, (from: 1, to: 5));
  });

  group('rejects', () {
    final bad = <String, String>{
      'not json': 'nope',
      'not object': '[1]',
      'missing t': '{"v":1}',
      'unknown type': '{"t":"bogus"}',
      'wrong int type': '{"t":"ping","ts":"1"}',
      'negative seq': '{"t":"ack","session":"$sid","seq":-1}',
      'zero cols': '{"t":"resize","session":"$sid","cols":0,"rows":5}',
      'huge cols': '{"t":"resize","session":"$sid","cols":70000,"rows":5}',
      'bad session id': '{"t":"detach","session":"xyz"}',
      'unknown signal': '{"t":"signal","session":"$sid","sig":"HUP"}',
      'name too long': '{"t":"rename","session":"$sid","name":"${'n' * 65}"}',
      'caps not list': '{"t":"hello","v":1,"client":"c","caps":"x"}',
    };
    bad.forEach((name, text) {
      test(name, () {
        expect(
          () => decodeClientMessage(text),
          throwsA(isA<ProtocolException>()),
        );
      });
    });

    test('oversized control message', () {
      final text =
          '{"t":"ping","ts":1,"pad":"${'x' * Limits.maxControlMessageBytes}"}';
      expect(
        () => decodeClientMessage(text),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('unknown error code from server', () {
      expect(
        () => decodeServerMessage('{"t":"error","code":"weird","msg":"m"}'),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  test('unknown fields are ignored (forward compatibility)', () {
    final m = decodeClientMessage('{"t":"ping","ts":5,"future":true}') as Ping;
    expect(m.ts, 5);
  });
}
