import 'dart:io';

import 'package:test/test.dart';
import 'package:tp_agent/src/auth/password.dart';
import 'package:tp_agent/src/auth/totp.dart';
import 'package:tp_agent/src/cli/config_edit.dart';
import 'package:tp_agent/src/cli/console.dart';
import 'package:tp_agent/tp_agent.dart';

void main() {
  late Directory dir;
  late String path;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tp_cli_');
    path = '${dir.path}/config.toml';
    out = StringBuffer();
    err = StringBuffer();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<int?> run(List<String> args, [List<String> answers = const []]) =>
      buildRunner(
        out: out,
        err: err,
        console: ScriptedConsole(answers),
        cost: Argon2Cost.test,
      ).run(args);

  String mode(String p) =>
      Process.runSync('stat', ['-c', '%a', p]).stdout.toString().trim();

  test(
    'init generates a password, writes a private valid config and refuses to overwrite',
    () async {
      expect(await run(['init', '--config', path, '--state-dir', dir.path]), 0);
      final password = RegExp(
        r'Password \(shown once, write it down\):\s+(\S+)',
      ).firstMatch(out.toString())!.group(1)!;
      expect(checkPasswordStrength(password), isNull);
      expect(mode(path), '600');
      final config = AgentConfig.parse(File(path).readAsStringSync());
      expect(config.auth.isConfigured, isTrue);
      expect(verifyPassword(password, config.auth.passwordHash), isTrue);
      expect(config.auth.stateFile, '${dir.path}/auth.json');
      expect(File(path).readAsStringSync(), isNot(contains(password)));

      expect(await run(['init', '--config', path]), 73);
    },
  );

  test('init with a password file enforces the policy', () async {
    final pw = File('${dir.path}/pw')..writeAsStringSync('short\n');
    expect(
      await run(['init', '--config', path, '--password-file', pw.path]),
      65,
    );
    expect(err.toString(), contains('at least 12'));
    pw.writeAsStringSync('contortionist\n');
    expect(
      await run(['init', '--config', path, '--password-file', pw.path]),
      65,
    );
    expect(err.toString(), contains('commonly used'));
    pw.writeAsStringSync('a-long-and-unusual-one\n');
    expect(
      await run([
        'init',
        '--config',
        path,
        '--password-file',
        pw.path,
        '--mode',
        'standalone',
        '--public-origin',
        'https://tp.example.com',
      ]),
      0,
    );
    final config = AgentConfig.parse(File(path).readAsStringSync());
    expect(config.mode, AgentMode.standalone);
    expect(config.listenPort, 443);
    expect(config.publicOrigin.toString(), 'https://tp.example.com');
  });

  test(
    'passwd asks twice, keeps comments, and replaces only the hash',
    () async {
      await run(['init', '--config', path, '--state-dir', dir.path]);
      final before = File(path).readAsStringSync();
      expect(
        await run(
          ['passwd', '--config', path],
          ['new-password-one', 'new-password-two'],
        ),
        65,
      );
      expect(err.toString(), contains('do not match'));
      expect(
        await run(
          ['passwd', '--config', path],
          ['new-password-one', 'new-password-one'],
        ),
        0,
      );
      final after = File(path).readAsStringSync();
      expect(after, contains('# Terminal Prompter agent configuration'));
      final config = AgentConfig.parse(after);
      expect(
        verifyPassword('new-password-one', config.auth.passwordHash),
        isTrue,
      );
      expect(before.split('\n').length, after.split('\n').length);
      expect(mode(path), '600');
    },
  );

  test(
    'totp enable shows a QR code, needs a valid code, then disable clears it',
    () async {
      await run(['init', '--config', path, '--state-dir', dir.path]);
      // A wrong code three times: nothing is written.
      expect(
        await run(
          ['totp', 'enable', '--config', path],
          ['000000', '111111', '222222'],
        ),
        65,
      );
      expect(
        AgentConfig.parse(File(path).readAsStringSync()).totpEnabledForTest,
        isFalse,
      );

      // Read the secret from the printed key and answer with the right code.
      out.clear();
      final runner = buildRunner(
        out: out,
        err: err,
        console: _TotpConsole(out),
        cost: Argon2Cost.test,
      );
      expect(
        await runner.run([
          'totp',
          'enable',
          '--config',
          path,
          '--account',
          'test-host',
        ]),
        0,
      );
      expect(out.toString(), contains('█'));
      final config = AgentConfig.parse(File(path).readAsStringSync());
      expect(config.auth.totpSecret, hasLength(32));

      expect(await run(['totp', 'disable', '--config', path]), 0);
      expect(
        AgentConfig.parse(File(path).readAsStringSync()).auth.totpSecret,
        isEmpty,
      );
    },
  );

  test('setTomlValue inserts missing keys and sections', () {
    File(path).writeAsStringSync(
      '# top\nmode = "proxy"\n\n[auth]\nsession_ttl = "1h"\n\n[shell]\ncommand = "/bin/sh"\n',
    );
    setTomlValue(path, 'auth', 'totp_secret', tomlString('ABC'));
    setTomlValue(path, 'audit', 'enabled', 'false');
    final text = File(path).readAsStringSync();
    expect(
      text,
      contains('[auth]\nsession_ttl = "1h"\ntotp_secret = \'ABC\'\n\n[shell]'),
    );
    expect(text, endsWith('[audit]\nenabled = false\n'));
    expect(tomlString("it's"), '"it\'s"');
  });
}

/// Answers the TOTP prompt with the current code for the key it printed.
final class _TotpConsole implements Console {
  _TotpConsole(this.out);

  final StringBuffer out;

  @override
  String? ask(String prompt, {bool secret = false}) {
    final key = RegExp(
      r'enter the key manually: ([A-Z2-7 ]+)',
    ).firstMatch(out.toString())!.group(1)!.replaceAll(' ', '');
    return Totp.fromBase32(key).codeAt(DateTime.now());
  }
}

extension on AgentConfig {
  bool get totpEnabledForTest => auth.totpSecret.isNotEmpty;
}
