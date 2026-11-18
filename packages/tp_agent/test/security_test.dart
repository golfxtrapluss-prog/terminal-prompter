@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:tp_agent/src/audit/audit_log.dart';
import 'package:tp_agent/src/auth/auth_service.dart';
import 'package:tp_agent/src/auth/auth_store.dart';
import 'package:tp_agent/src/auth/password.dart';
import 'package:tp_agent/src/auth/totp.dart';
import 'package:tp_agent/src/log.dart';
import 'package:tp_agent/tp_agent.dart';
import 'package:tp_protocol/tp_protocol.dart';

const password = 'Sjøsprøyt-og-satellitt-2026';
const ua = 'tp-security-test/1.0';

/// One running agent with authentication and a fresh temp directory.
final class Harness {
  Harness._(this.dir, this.server, this.sessions, this.audit, this.totp);

  static Future<Harness> start({bool withTotp = false}) async {
    final dir = await Directory.systemTemp.createTemp('tp_sec_');
    await File('${dir.path}/index.html').writeAsString('<title>tp</title>');
    final totp = withTotp ? Totp.generate() : null;
    final hash = hashPassword(password, cost: Argon2Cost.test);
    final config = AgentConfig.parse('''
mode = "proxy"
listen = "127.0.0.1:1"

[auth]
password_hash = '$hash'
totp_secret = "${totp?.base32Secret ?? ''}"
max_failed_logins = 5
lockout = "15m"
state_file = "${dir.path}/auth.json"

[shell]
command = "/bin/bash"
args = ["--norc", "--noprofile", "-i"]
env = { TERM = "xterm-256color", PS1 = "TP\$ ", LANG = "C.UTF-8" }

[transport]
output_coalesce = "5ms"

[audit]
path = "${dir.path}/audit.jsonl"
''');
    final audit = AuditLog(path: config.audit.path);
    final auth = AuthService(
      config: config,
      store: AuthStore(config.auth.stateFile),
      audit: audit,
      backupCodeCost: Argon2Cost.test,
    );
    final sessions = SessionManager(config: config, audit: audit);
    final server = AgentServer(
      config: config,
      sessions: sessions,
      staticFiles: DirectoryStaticFiles(dir.path),
      agentVersion: 'sec',
      auth: auth,
      audit: audit,
      port: 0,
    );
    await server.start();
    return Harness._(dir, server, sessions, audit, totp);
  }

  final Directory dir;
  final AgentServer server;
  final SessionManager sessions;
  final AuditLog audit;
  final Totp? totp;
  final HttpClient http = HttpClient();

  String get origin => 'http://127.0.0.1:${server.port}';
  Uri url(String path) => Uri.parse('$origin/$path');

  Future<void> stop() async {
    http.close(force: true);
    await server.stop();
    await sessions.shutdown();
    audit.close();
    await dir.delete(recursive: true);
  }

  Future<Res> request(
    String method,
    String path, {
    Object? json,
    String? origin,
    bool sendOrigin = true,
    Cookies? cookies,
    bool csrf = true,
    String contentType = 'application/json',
    String userAgent = ua,
    String? forwardedFor,
  }) async {
    final req = await http.openUrl(method, url(path));
    req.headers.set(HttpHeaders.userAgentHeader, userAgent);
    if (sendOrigin) req.headers.set('origin', origin ?? this.origin);
    if (forwardedFor != null) req.headers.set('x-forwarded-for', forwardedFor);
    if (cookies != null) {
      req.cookies.addAll([
        Cookie('tp_session', cookies.session),
        Cookie('tp_csrf', cookies.csrf),
      ]);
      if (csrf) req.headers.set('x-tp-csrf', cookies.csrf);
    }
    if (json != null) {
      req.headers.set(HttpHeaders.contentTypeHeader, contentType);
      req.add(utf8.encode(jsonEncode(json))); // JSON is UTF-8 (RFC 8259)
    }
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    return Res(
      res.statusCode,
      body.isEmpty ? null : jsonDecode(body),
      res.cookies,
      res.headers,
    );
  }

  Future<Cookies> login({String? totpCode}) async {
    final r = await request(
      'POST',
      'api/login',
      json: {'password': password, 'totp': ?totpCode},
    );
    expect(r.status, 200, reason: '${r.body}');
    return Cookies.from(r);
  }

  Future<WebSocket> ws({
    Cookies? cookies,
    String? origin,
    String userAgent = ua,
  }) {
    final headers = <String, Object>{'origin': origin ?? this.origin};
    if (cookies != null) headers['cookie'] = 'tp_session=${cookies.session}';
    // WebSocket.connect ignores a user-agent entry in [headers]; the client's
    // own userAgent is what the server sees.
    final client = HttpClient()..userAgent = userAgent;
    return WebSocket.connect(
      'ws://127.0.0.1:${server.port}/api/ws',
      headers: headers,
      customClient: client,
    );
  }

  List<Map<String, Object?>> auditEvents() => [
    for (final line in File('${dir.path}/audit.jsonl').readAsLinesSync())
      if (line.isNotEmpty) jsonDecode(line) as Map<String, Object?>,
  ];
}

final class Res {
  Res(this.status, this.body, this.cookies, this.headers);

  final int status;
  final Object? body;
  final List<Cookie> cookies;
  final HttpHeaders headers;

  Map<String, Object?> get map => body! as Map<String, Object?>;
}

final class Cookies {
  Cookies(this.session, this.csrf);

  factory Cookies.from(Res r) {
    final s = r.cookies.firstWhere((c) => c.name == 'tp_session');
    final c = r.cookies.firstWhere((c) => c.name == 'tp_csrf');
    expect(s.httpOnly, isTrue);
    expect(s.secure, isTrue);
    expect(s.sameSite, SameSite.strict);
    expect(c.httpOnly, isFalse);
    expect(c.value, r.map['csrf']);
    return Cookies(s.value, c.value);
  }

  final String session;
  final String csrf;
}

void main() {
  final logs = StringBuffer();
  setUpAll(() => installJsonLogging(level: Level.ALL, sink: logs));

  group('without TOTP', () {
    late Harness h;
    setUp(() async => h = await Harness.start());
    tearDown(() => h.stop());

    test('API and WebSocket need a login; wrong Origin is refused', () async {
      expect((await h.request('GET', 'api/me')).status, 401);
      expect((await h.request('POST', 'api/logout', json: {})).status, 401);

      await expectLater(
        h.ws(),
        throwsA(isA<WebSocketException>()),
        reason: 'no cookie -> 401',
      );
      final cookies = await h.login();
      await expectLater(
        h.ws(cookies: cookies, origin: 'https://evil.example'),
        throwsA(isA<WebSocketException>()),
        reason: 'wrong Origin -> 403',
      );
      await expectLater(
        h.ws(cookies: cookies, userAgent: 'other-browser'),
        throwsA(isA<WebSocketException>()),
        reason: 'User-Agent binding',
      );

      // The UA mismatch ended that login; log in again and connect for real.
      final fresh = await h.login();
      final socket = await h.ws(cookies: fresh);
      final hello = Completer<ServerHello>();
      socket.listen((e) {
        if (e is String && !hello.isCompleted) {
          hello.complete(decodeServerMessage(e) as ServerHello);
        }
      });
      socket.add(
        encodeMessage(
          const ClientHello(version: protocolVersion, client: 'sec'),
        ),
      );
      expect(
        (await hello.future.timeout(const Duration(seconds: 5))).agent,
        'sec',
      );
      await socket.close();
    });

    test('login POST: Origin, content type and body checks', () async {
      expect(
        (await h.request(
          'POST',
          'api/login',
          json: {'password': password},
          origin: 'https://evil.example',
        )).status,
        403,
      );
      expect(
        (await h.request(
          'POST',
          'api/login',
          json: {'password': password},
          sendOrigin: false,
        )).status,
        403,
      );
      expect(
        (await h.request(
          'POST',
          'api/login',
          json: {'password': password},
          contentType: 'text/plain',
        )).status,
        415,
      );
      expect((await h.request('POST', 'api/login', json: ['x'])).status, 400);
      final wrong = await h.request(
        'POST',
        'api/login',
        json: {'password': 'nope-nope-nope'},
      );
      expect(wrong.status, 401);
      expect(wrong.map['error'], 'invalid_credentials');
    });

    test('CSRF: authenticated POST needs the matching header', () async {
      final c = await h.login();
      expect(
        (await h.request(
          'POST',
          'api/auth/backup-codes',
          json: {},
          cookies: c,
          csrf: false,
        )).status,
        403,
      );
      final bad = Cookies(c.session, 'forged');
      expect(
        (await h.request(
          'POST',
          'api/auth/backup-codes',
          json: {},
          cookies: bad,
        )).status,
        403,
      );
      final ok = await h.request(
        'POST',
        'api/auth/backup-codes',
        json: {},
        cookies: c,
      );
      expect(ok.status, 200);
      expect((ok.map['codes']! as List).length, 10);
    });

    test(
      'lockout after max_failed_logins, across IPs, and correct password is refused while locked',
      () async {
        for (var i = 0; i < 5; i++) {
          final r = await h.request(
            'POST',
            'api/login',
            json: {'password': 'wrong-$i-wrong-wrong'},
            forwardedFor: '198.51.100.$i',
          );
          expect(r.status, 401);
        }
        final locked = await h.request(
          'POST',
          'api/login',
          json: {'password': password},
          forwardedFor: '198.51.100.99',
        );
        expect(locked.status, 429);
        expect(locked.map['error'], 'locked');
        expect(
          int.parse(locked.headers.value('retry-after')!),
          greaterThan(800),
        );
        expect(h.auditEvents().map((e) => e['ev']), contains('lockout'));
      },
    );

    test(
      'per-IP rate limit: sixth attempt within a minute is refused',
      () async {
        for (var i = 0; i < 4; i++) {
          await h.request(
            'POST',
            'api/login',
            json: {'password': 'wrong-wrong-wrong-$i'},
            forwardedFor: '203.0.113.7',
          );
        }
        await h.request(
          'POST',
          'api/login',
          json: {'password': password},
          forwardedFor: '203.0.113.7',
        );
        final sixth = await h.request(
          'POST',
          'api/login',
          json: {'password': password},
          forwardedFor: '203.0.113.7',
        );
        expect(sixth.status, 429);
        expect(sixth.map['error'], 'rate_limited');
      },
    );

    test('backup code works exactly once and replaces the password', () async {
      final c = await h.login();
      final codes =
          ((await h.request(
                    'POST',
                    'api/auth/backup-codes',
                    json: {},
                    cookies: c,
                  )).map['codes']!
                  as List)
              .cast<String>();
      final first = await h.request(
        'POST',
        'api/login',
        json: {'backup_code': codes[2].toLowerCase()},
      );
      expect(first.status, 200);
      expect(first.map['backup_codes_left'], 9);
      final again = await h.request(
        'POST',
        'api/login',
        json: {'backup_code': codes[2]},
      );
      expect(again.status, 401);
      final me = await h.request('GET', 'api/me', cookies: Cookies.from(first));
      expect((me.map['backup_codes']! as Map)['remaining'], 9);
      expect((me.map['login']! as Map)['method'], 'backupCode');
    });

    test(
      'logout ends the login and closes its WebSockets; logout-all ends others',
      () async {
        final c = await h.login();
        final other = await h.login();
        final socket = await h.ws(cookies: c);
        final closed = Completer<int?>();
        socket.listen((_) {}, onDone: () => closed.complete(socket.closeCode));
        final me = await h.request('GET', 'api/me', cookies: c);
        expect((me.map['logins']! as List).length, 2);

        expect(
          (await h.request('POST', 'api/logout', json: {}, cookies: c)).status,
          200,
        );
        expect(await closed.future.timeout(const Duration(seconds: 5)), 4401);
        expect((await h.request('GET', 'api/me', cookies: c)).status, 401);

        final third = await h.login();
        expect(
          (await h.request(
            'POST',
            'api/logout-all',
            json: {},
            cookies: third,
          )).status,
          200,
        );
        expect((await h.request('GET', 'api/me', cookies: other)).status, 401);
      },
    );

    test(
      'Prompter lines are audited, raw input is not, password answers are masked',
      () async {
        final c = await h.login();
        final socket = await h.ws(cookies: c);
        final inbox = <ServerMessage>[];
        final out = StringBuffer();
        socket.listen((e) {
          if (e is String) inbox.add(decodeServerMessage(e));
          if (e is List<int>) {
            final f = decodeBinaryFrame(Uint8List.fromList(e));
            if (f is OutputFrame) out.write(latin1.decode(f.data));
          }
        });
        Future<T> next<T>() async {
          for (var i = 0; i < 500; i++) {
            final m = inbox.whereType<T>().firstOrNull;
            if (m != null) {
              inbox.remove(m);
              return m;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          throw TimeoutException('no $T');
        }

        Future<void> waitOut(String s) async {
          for (var i = 0; i < 500 && !out.toString().contains(s); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(out.toString(), contains(s));
        }

        socket.add(
          encodeMessage(
            const ClientHello(version: protocolVersion, client: 'sec'),
          ),
        );
        await next<ServerHello>();
        socket.add(encodeMessage(const Attach(cols: 80, rows: 24)));
        final sid = (await next<Attached>()).session;
        await waitOut(r'TP$ ');

        socket.add(
          encodeInputFrame(
            sid,
            1,
            utf8.encode('echo audited-line\r'),
            fromPrompter: true,
          ),
        );
        socket.add(
          encodeInputFrame(sid, 2, utf8.encode('echo raw-not-audited\r')),
        );
        await waitOut('raw-not-audited\r\n');
        socket.add(
          encodeInputFrame(
            sid,
            3,
            utf8.encode(
              "read -rs -p 'Password: ' pw; echo; echo len=\${#pw}\r",
            ),
            fromPrompter: true,
          ),
        );
        await waitOut('Password: ');
        socket.add(
          encodeInputFrame(
            sid,
            4,
            utf8.encode('hunter2-secret\r'),
            fromPrompter: true,
          ),
        );
        await waitOut('len=14');
        await socket.close();

        final lines = [
          for (final e in h.auditEvents())
            if (e['ev'] == 'cmd') e['line'],
        ];
        expect(lines, [
          'echo audited-line',
          r"read -rs -p 'Password: ' pw; echo; echo len=${#pw}",
          '***',
        ]);
        final events = h.auditEvents().map((e) => e['ev']).toList();
        expect(events, containsAll(['login_ok', 'session_start']));
      },
    );
  });

  group('with TOTP', () {
    late Harness h;
    setUp(() async => h = await Harness.start(withTotp: true));
    tearDown(() => h.stop());

    test(
      'password alone fails, password + code works, the code cannot be reused',
      () async {
        expect(
          (await h.request('GET', 'api/auth/methods')).map['totp'],
          isTrue,
        );
        expect(
          (await h.request(
            'POST',
            'api/login',
            json: {'password': password},
          )).status,
          401,
        );
        final code = h.totp!.codeAt(DateTime.now());
        await h.login(totpCode: code);
        final replay = await h.request(
          'POST',
          'api/login',
          json: {'password': password, 'totp': code},
        );
        expect(replay.status, 401, reason: 'same code twice');
        expect(
          (await h.request(
            'POST',
            'api/login',
            json: {
              'password': 'wrong-password-x',
              'totp': h.totp!.codeAt(DateTime.now()),
            },
          )).status,
          401,
        );
      },
    );
  });

  test('no secrets in logs or audit (grep test, docs/12 M5)', () async {
    final h = await Harness.start(withTotp: true);
    final secrets = <String>[password];
    final code = h.totp!.codeAt(DateTime.now());
    secrets
      ..add(h.totp!.base32Secret)
      ..add(code);
    final c = await h.login(totpCode: code);
    secrets
      ..add(c.session)
      ..add(c.csrf);
    final codes =
        ((await h.request(
                  'POST',
                  'api/auth/backup-codes',
                  json: {},
                  cookies: c,
                )).map['codes']!
                as List)
            .cast<String>();
    secrets.addAll(codes);
    secrets.addAll(codes.map((x) => x.replaceAll('-', '')));
    final b = await h.request(
      'POST',
      'api/login',
      json: {'backup_code': codes.first},
    );
    secrets.add(Cookies.from(b).session);
    await h.request(
      'POST',
      'api/login',
      json: {'password': 'wrong-but-also-secret-1'},
    );
    secrets.add('wrong-but-also-secret-1');
    final auditText = File('${h.dir.path}/audit.jsonl').readAsStringSync();
    final stateText = File('${h.dir.path}/auth.json').readAsStringSync();
    await h.stop();

    final logText = logs.toString();
    for (final s in secrets) {
      expect(logText, isNot(contains(s)), reason: 'log leaks a secret');
      expect(auditText, isNot(contains(s)), reason: 'audit leaks a secret');
      expect(
        stateText,
        isNot(contains(s)),
        reason: 'state file stores a plain secret',
      );
    }
    expect(auditText, contains('login_ok'));
  });
}
