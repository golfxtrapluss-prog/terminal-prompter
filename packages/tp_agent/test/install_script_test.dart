@Tags(['install'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:tp_agent/src/auth/password.dart';
import 'package:tp_agent/src/config/config.dart';

/// Runs install/install.sh end to end in a sandbox (TP_ROOT) under dash and
/// BusyBox sh, against a local "release" server with a real compiled agent.
/// Run with `make install-test`.
void main() {
  late Directory work;
  late HttpServer server;
  late String binary;
  final script = File('../../install/install.sh').absolute.path;

  setUpAll(() async {
    work = Directory.systemTemp.createTempSync('tp_install_');
    binary = '${work.path}/release/tp-agent-linux-x64';
    Directory('${work.path}/release').createSync();
    final r = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '-o',
      binary,
      'bin/tp_agent.dart',
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final sum = sha256.convert(File(binary).readAsBytesSync());
    File(
      '${work.path}/release/SHA256SUMS',
    ).writeAsStringSync('# version 0.0.0-test\n$sum  tp-agent-linux-x64\n');
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final f = File(
        '${work.path}/release${req.uri.path.replaceFirst(RegExp('^/rel'), '')}',
      );
      if (f.existsSync()) {
        await req.response.addStream(f.openRead());
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
    work.deleteSync(recursive: true);
  });

  Future<ProcessResult> install(
    String shell,
    String root,
    List<String> args, {
    Map<String, String> env = const {},
  }) => Process.run(
    shell == 'busybox' ? 'busybox' : shell,
    [
      if (shell == 'busybox') 'sh',
      script,
      '--base-url',
      'http://127.0.0.1:${server.port}/rel',
      ...args,
    ],
    environment: {
      'TP_ROOT': root,
      'TP_NO_USER': '1',
      'TP_NO_SYSTEMD': '1',
      'TP_HOME': '$root/home/tp',
      ...env,
    },
  );

  for (final shell in ['dash', 'busybox']) {
    group(shell, () {
      test(
        'installs binary, private config with a working password, unit and sudoers',
        () async {
          final root = Directory('${work.path}/$shell-root')..createSync();
          final pw = File('${work.path}/pw')
            ..writeAsStringSync('a-long-and-unusual-password\n');
          final r = await install(shell, root.path, [
            '--yes',
            '--sudo',
            '--password-file',
            pw.path,
            '--domain',
            'tp.example.com',
          ]);
          expect(
            r.exitCode,
            0,
            reason: 'stdout: ${r.stdout}\nstderr: ${r.stderr}',
          );
          expect(r.stdout, contains('Checksum OK'));
          expect(r.stdout, contains('https://tp.example.com/'));

          final bin = File('${root.path}/usr/local/bin/tp-agent');
          expect(bin.existsSync(), isTrue);
          expect(
            Process.runSync(bin.path, ['version']).stdout,
            contains('tp-agent'),
          );

          final configFile = '${root.path}/etc/tp-agent/config.toml';
          final config = AgentConfig.parse(File(configFile).readAsStringSync());
          expect(
            verifyPassword(
              'a-long-and-unusual-password',
              config.auth.passwordHash,
            ),
            isTrue,
          );
          expect(config.publicOrigin.toString(), 'https://tp.example.com');
          expect(
            config.auth.stateFile,
            '${root.path}/var/lib/tp-agent/auth.json',
          );
          String mode(String p) =>
              Process.runSync('stat', ['-c', '%a', p]).stdout.toString().trim();
          expect(mode(configFile), '600');
          expect(mode('${root.path}/etc/tp-agent'), '700');

          final unit = File(
            '${root.path}/etc/systemd/system/tp-agent.service',
          ).readAsStringSync();
          expect(
            unit,
            contains(
              'ExecStart=/usr/local/bin/tp-agent run --config /etc/tp-agent/config.toml',
            ),
          );
          expect(unit, isNot(contains('CAP_NET_BIND_SERVICE')));
          final sudoers = File('${root.path}/etc/sudoers.d/tp-agent');
          expect(sudoers.readAsStringSync(), 'tp ALL=(ALL) NOPASSWD: ALL\n');
          expect(mode(sudoers.path), '440');

          // No web server found and --yes: the Caddy snippet is printed, not written.
          expect(r.stdout, contains('reverse_proxy 127.0.0.1:7681'));
          expect(
            File('${root.path}/etc/caddy/Caddyfile').existsSync(),
            isFalse,
          );

          // Running again keeps the config.
          final again = await install(shell, root.path, ['--yes', '--no-sudo']);
          expect(again.exitCode, 0, reason: '${again.stderr}');
          expect(again.stdout, contains('Keeping existing'));
        },
      );

      test(
        'generated password is printed once; standalone and Coolify listen addresses',
        () async {
          final root = Directory('${work.path}/$shell-gen')..createSync();
          final r = await install(shell, root.path, [
            '--yes',
            '--no-sudo',
            '--mode',
            'standalone',
          ]);
          expect(r.exitCode, 0, reason: '${r.stderr}');
          final pw = RegExp(
            r'Password \(shown once, write it down\):\s+(\S+)',
          ).firstMatch(r.stdout as String)?.group(1);
          expect(pw, isNotNull);
          final config = AgentConfig.parse(
            File('${root.path}/etc/tp-agent/config.toml').readAsStringSync(),
          );
          expect(verifyPassword(pw!, config.auth.passwordHash), isTrue);
          expect(config.listenPort, 443);
          expect(
            File(
              '${root.path}/etc/systemd/system/tp-agent.service',
            ).readAsStringSync(),
            contains('CAP_NET_BIND_SERVICE'),
          );
          expect(
            File('${root.path}/etc/sudoers.d/tp-agent').existsSync(),
            isFalse,
          );

          final coolify = Directory('${work.path}/$shell-coolify')
            ..createSync();
          final c = await install(
            shell,
            coolify.path,
            ['--yes', '--no-sudo', '--domain', 'tp.example.com'],
            env: {'TP_FAKE_SERVER': 'traefik'},
          );
          expect(c.exitCode, 0, reason: '${c.stderr}');
          final cc = AgentConfig.parse(
            File('${coolify.path}/etc/tp-agent/config.toml').readAsStringSync(),
          );
          expect('${cc.listenHost}:${cc.listenPort}', '172.17.0.1:7681');
          expect(c.stdout, contains('host.docker.internal:7681'));
        },
      );

      test('refuses a tampered binary, bad options and --link', () async {
        final root = Directory('${work.path}/$shell-bad')..createSync();
        final sums = File('${work.path}/release/SHA256SUMS');
        final original = sums.readAsStringSync();
        sums.writeAsStringSync(
          original.replaceFirst(RegExp(r'^[0-9a-f]', multiLine: true), 'f'),
        );
        addTearDown(() => sums.writeAsStringSync(original));
        final r = await install(shell, root.path, ['--yes']);
        expect(r.exitCode, isNot(0));
        expect(r.stderr, contains('checksum mismatch'));
        expect(
          File('${root.path}/usr/local/bin/tp-agent').existsSync(),
          isFalse,
        );
        sums.writeAsStringSync(original);

        final bad = await install(shell, root.path, ['--frobnicate']);
        expect(bad.exitCode, 64);
        final link = await install(shell, root.path, [
          '--link',
          'TPLK-1234-5678',
        ]);
        expect(link.exitCode, 1);
        expect(link.stderr, contains('v1.5'));
        final domain = await install(shell, root.path, [
          '--domain',
          'evil;rm -rf /',
        ]);
        expect(domain.stderr, contains('invalid domain'));
      });
    });
  }
}
