import 'package:test/test.dart';
import 'package:tp_agent/src/config/config.dart';

void main() {
  test('defaults apply to an empty document', () {
    final c = AgentConfig.parse('');
    expect(c.mode, AgentMode.proxy);
    expect(c.listenHost, '127.0.0.1');
    expect(c.listenPort, 7681);
    expect(c.basePath, '/');
    expect(c.shell.command, '/bin/bash');
    expect(c.shell.args, ['-l']);
    expect(c.sessions.max, 8);
    expect(c.sessions.scrollbackBytes, 1024 * 1024);
    expect(c.transport.outputCoalesce, const Duration(milliseconds: 25));
    expect(c.auth.isConfigured, isFalse);
    expect(c.listensOnLoopback, isTrue);
  });

  test('parses the documented example', () {
    final c = AgentConfig.parse('''
mode = "proxy"
listen = "[::1]:8000"
base_path = "tp-9f3k2"
public_origin = "https://tp.example.com"

[auth]
password_hash = "\$argon2id\$v=19\$m=65536,t=3,p=2\$abc"
session_ttl = "2h"

[shell]
command = "/bin/zsh"
args = []
env = { TERM = "xterm", FOO = "bar" }
wrap = "tmux"

[sessions]
max = 2
idle_timeout = "30m"
scrollback_bytes = "256KB"

[transport]
heartbeat = "10s"
compression = false
''');
    expect(c.listenHost, '::1');
    expect(c.listenPort, 8000);
    expect(c.basePath, '/tp-9f3k2/');
    expect(c.publicOrigin, Uri.parse('https://tp.example.com'));
    expect(c.auth.isConfigured, isTrue);
    expect(c.auth.sessionTtl, const Duration(hours: 2));
    expect(c.shell.command, '/bin/zsh');
    expect(c.shell.args, isEmpty);
    expect(c.shell.env, {'TERM': 'xterm', 'FOO': 'bar'});
    expect(c.shell.wrap, ShellWrap.tmux);
    expect(c.sessions.max, 2);
    expect(c.sessions.idleTimeout, const Duration(minutes: 30));
    expect(c.sessions.scrollbackBytes, 256 * 1024);
    expect(c.transport.heartbeat, const Duration(seconds: 10));
    expect(c.transport.compression, isFalse);
  });

  test('environment overrides win over the file', () {
    final c = AgentConfig.parse(
      'listen = "127.0.0.1:1"\n[sessions]\nmax = 3\n',
      environment: {
        'TP_LISTEN': '127.0.0.1:9',
        'TP_SESSIONS_MAX': '5',
        'TP_SHELL_COMMAND': '/bin/sh',
        'TP_TRANSPORT_COMPRESSION': 'no',
      },
    );
    expect(c.listenPort, 9);
    expect(c.sessions.max, 5);
    expect(c.shell.command, '/bin/sh');
    expect(c.transport.compression, isFalse);
  });

  test('refuses a public listen address without a password', () {
    expect(
      () => AgentConfig.parse('listen = "0.0.0.0:7681"'),
      throwsA(isA<ConfigValueError>().having((e) => e.key, 'key', 'listen')),
    );
  });

  test('standalone requires tls files', () {
    expect(
      () => AgentConfig.parse('mode = "standalone"'),
      throwsA(isA<ConfigValueError>().having((e) => e.key, 'key', 'tls')),
    );
    final ok = AgentConfig.parse(
      'mode = "standalone"\n[tls]\ncert_file = "a.pem"\nkey_file = "b.pem"\n',
    );
    expect(ok.tls?.certFile, 'a.pem');
  });

  test('rejects bad values with the dotted key', () {
    expect(
      () => AgentConfig.parse('mode = "weird"'),
      throwsA(isA<ConfigValueError>().having((e) => e.key, 'key', 'mode')),
    );
    expect(
      () => AgentConfig.parse('listen = "nope"'),
      throwsA(isA<ConfigValueError>().having((e) => e.key, 'key', 'listen')),
    );
    expect(
      () => AgentConfig.parse('[sessions]\nmax = 0'),
      throwsA(
        isA<ConfigValueError>().having((e) => e.key, 'key', 'sessions.max'),
      ),
    );
    expect(
      () => AgentConfig.parse('[transport]\nheartbeat = "soon"'),
      throwsA(
        isA<ConfigValueError>().having(
          (e) => e.key,
          'key',
          'transport.heartbeat',
        ),
      ),
    );
    expect(
      () => AgentConfig.parse('listen = = 1'),
      throwsA(isA<ConfigParseError>()),
    );
  });

  test('duration and size parsing', () {
    expect(parseDuration('25ms'), const Duration(milliseconds: 25));
    expect(parseDuration('3d'), const Duration(days: 3));
    expect(() => parseDuration('5'), throwsFormatException);
    expect(parseBytes('1048576'), 1048576);
    expect(parseBytes('256KB'), 262144);
    expect(parseBytes('2GB'), 2147483648);
    expect(parseBytes('64MiB'), 67108864);
    expect(() => parseBytes('lots'), throwsFormatException);
  });
}
