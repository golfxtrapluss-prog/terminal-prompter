import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../auth/password.dart';
import '../auth/totp.dart';
import '../config/config.dart';
import '../log_util.dart';
import 'config_edit.dart';
import 'console.dart';
import 'qr.dart';

const String _defaultConfig = '/etc/tp-agent/config.toml';
const String _restartHint =
    'Restart the agent to apply: sudo systemctl restart tp-agent';

/// Reads a new password from `--password-file` or interactively (twice), and
/// enforces the policy from docs/05. Returns null after printing why not.
String? _newPassword(ArgResults args, Console console, StringSink err) {
  final file = args.option('password-file');
  String? password;
  if (file != null) {
    password = File(file).readAsStringSync().trim();
  } else {
    password = console.ask('New password (min. 12 characters): ', secret: true);
    final again = console.ask('Repeat: ', secret: true);
    if (password != again) {
      err.writeln('Passwords do not match.');
      return null;
    }
  }
  if (password == null || password.isEmpty) {
    err.writeln('No password given.');
    return null;
  }
  switch (checkPasswordStrength(password)) {
    case PasswordProblem.tooShort:
      err.writeln('Too short: use at least 12 characters.');
      return null;
    case PasswordProblem.common:
      err.writeln('That password is on a list of commonly used passwords.');
      return null;
    case null:
      return password;
  }
}

/// `tp-agent init`: writes a new config with a password (docs/02, docs/05).
final class InitCommand extends Command<int> {
  InitCommand({
    required this.out,
    required this.err,
    required this.console,
    this.cost = Argon2Cost.password,
  }) {
    argParser
      ..addOption(
        'config',
        abbr: 'c',
        defaultsTo: _defaultConfig,
        help: 'Where to write config.toml.',
      )
      ..addOption('mode', allowed: ['proxy', 'standalone'], defaultsTo: 'proxy')
      ..addOption(
        'listen',
        help:
            'host:port (default 127.0.0.1:7681, or 0.0.0.0:443 in standalone).',
      )
      ..addOption(
        'public-origin',
        help:
            'e.g. https://tp.example.com (used for Origin checks and passkeys).',
      )
      ..addOption(
        'state-dir',
        defaultsTo: '/var/lib/tp-agent',
        help: 'Directory for auth state and the audit log.',
      )
      ..addOption(
        'password-file',
        help: 'Read the password from this file instead of generating one.',
      )
      ..addFlag(
        'generate',
        defaultsTo: true,
        help:
            'Generate a strong password (default) unless --password-file is given.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Overwrite an existing config.',
      );
  }

  final StringSink out;
  final StringSink err;
  final Console console;
  final Argon2Cost cost;

  @override
  String get name => 'init';

  @override
  String get description =>
      'Create the configuration and set the first password.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final path = args.option('config')!;
    if (File(path).existsSync() && !args.flag('force')) {
      err.writeln(
        '$path already exists. Use "tp-agent passwd" to change the password, or --force to start over.',
      );
      return 73; // EX_CANTCREAT
    }
    final mode = args.option('mode')!;
    final listen =
        args.option('listen') ??
        (mode == 'standalone' ? '0.0.0.0:443' : '127.0.0.1:7681');
    final origin = args.option('public-origin') ?? '';
    final stateDir = args.option('state-dir')!;

    final String password;
    var generated = false;
    if (args.option('password-file') != null || !args.flag('generate')) {
      final p = _newPassword(args, console, err);
      if (p == null) return 65; // EX_DATAERR
      password = p;
    } else {
      password = generatePassword();
      generated = true;
    }
    final hash = await hashPasswordAsync(password, cost: cost);

    final text =
        '''
# Terminal Prompter agent configuration (docs/02-agent.md).
# Created by "tp-agent init". Keep this file private (mode 0600).

mode = "$mode"
listen = "$listen"
base_path = "/"
public_origin = "$origin"

${mode == 'standalone' ? '[tls]\ncert_file = "/etc/tp-agent/fullchain.pem"\nkey_file  = "/etc/tp-agent/privkey.pem"\n\n' : ''}[auth]
password_hash = ${tomlString(hash)}
totp_secret = ""
session_ttl = "12h"
idle_timeout = "4h"
max_failed_logins = 5
lockout = "15m"
state_file = "$stateDir/auth.json"

[shell]
command = "/bin/bash"
args = ["-l"]
env = { TERM = "xterm-256color", LANG = "C.UTF-8" }
workdir = "~"
wrap = "none"

[sessions]
max = 8
idle_timeout = "24h"
scrollback_bytes = 1048576

[transport]
heartbeat = "15s"
output_coalesce = "25ms"
compression = true
sse_fallback = true

[files]
enabled = true
max_upload = "2GB"
chunk_size = "256KB"
root = "~"

[audit]
enabled = true
log_input = true
path = "$stateDir/audit.jsonl"
''';
    // Validate what we are about to write.
    try {
      AgentConfig.parse(text);
    } on ConfigError catch (e) {
      err.writeln('Invalid settings: $e');
      return 64;
    }
    writePrivateFile(path, text);
    out.writeln('Wrote $path');
    if (generated) {
      out
        ..writeln()
        ..writeln('  Password (shown once, write it down):  $password')
        ..writeln();
    }
    out
      ..writeln(
        'Next: register a passkey and create backup codes in the web client',
      )
      ..writeln(
        '(Settings > Security), and optionally run "tp-agent totp enable".',
      );
    return 0;
  }
}

/// `tp-agent passwd`: changes the password hash in the config.
final class PasswdCommand extends Command<int> {
  PasswdCommand({
    required this.out,
    required this.err,
    required this.console,
    this.cost = Argon2Cost.password,
  }) {
    argParser
      ..addOption('config', abbr: 'c', defaultsTo: _defaultConfig)
      ..addOption(
        'password-file',
        help: 'Read the new password from this file.',
      );
  }

  final StringSink out;
  final StringSink err;
  final Console console;
  final Argon2Cost cost;

  @override
  String get name => 'passwd';

  @override
  String get description => 'Change the password.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final path = args.option('config')!;
    if (!File(path).existsSync()) {
      err.writeln('$path not found; run "tp-agent init" first.');
      return 66; // EX_NOINPUT
    }
    final password = _newPassword(args, console, err);
    if (password == null) return 65;
    final hash = await hashPasswordAsync(password, cost: cost);
    setTomlValue(path, 'auth', 'password_hash', tomlString(hash));
    out
      ..writeln('Password changed.')
      ..writeln(_restartHint);
    return 0;
  }
}

/// `tp-agent totp enable|disable` (docs/02, docs/05).
final class TotpCommand extends Command<int> {
  TotpCommand({
    required StringSink out,
    required StringSink err,
    required Console console,
  }) {
    addSubcommand(_TotpEnable(out, err, console));
    addSubcommand(_TotpDisable(out, err));
  }

  @override
  String get name => 'totp';

  @override
  String get description => 'Turn the authenticator-app code (TOTP) on or off.';
}

final class _TotpEnable extends Command<int> {
  _TotpEnable(this.out, this.err, this.console) {
    argParser
      ..addOption('config', abbr: 'c', defaultsTo: _defaultConfig)
      ..addOption(
        'account',
        help:
            'Name shown in the authenticator app (default: public origin host or hostname).',
      );
  }

  final StringSink out;
  final StringSink err;
  final Console console;

  @override
  String get name => 'enable';

  @override
  String get description =>
      'Create a TOTP secret, show it as a QR code and confirm with a code.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final path = args.option('config')!;
    final AgentConfig config;
    try {
      config = await AgentConfig.load(path);
    } on ConfigError catch (e) {
      err.writeln('tp-agent: $e');
      return 78;
    }
    final account =
        args.option('account') ??
        config.publicOrigin?.host ??
        Platform.localHostname;
    final totp = Totp.generate();
    final uri = totp.uri(account: account);
    out
      ..writeln('Scan this with your authenticator app:')
      ..writeln()
      ..write(QrCode.encode(uri).toTerminal())
      ..writeln()
      ..writeln('Or enter the key manually: ${_grouped(totp.base32Secret)}')
      ..writeln();
    for (var attempt = 0; attempt < 3; attempt++) {
      final code = console.ask(
        'Enter the 6-digit code from the app to confirm: ',
      );
      if (code == null) break;
      if (totp.verify(code, DateTime.now()) != null) {
        setTomlValue(
          path,
          'auth',
          'totp_secret',
          tomlString(totp.base32Secret),
        );
        out
          ..writeln(
            'TOTP enabled. Logins now need password + code (passkeys are unaffected).',
          )
          ..writeln(_restartHint);
        return 0;
      }
      err.writeln(
        'That code is not valid. Check the time on your phone and try again.',
      );
    }
    err.writeln('TOTP was not enabled.');
    return 65;
  }

  static String _grouped(String s) => [
    for (var i = 0; i < s.length; i += 4)
      s.substring(i, (i + 4).clamp(0, s.length)),
  ].join(' ');
}

final class _TotpDisable extends Command<int> {
  _TotpDisable(this.out, this.err) {
    argParser.addOption('config', abbr: 'c', defaultsTo: _defaultConfig);
  }

  final StringSink out;
  final StringSink err;

  @override
  String get name => 'disable';

  @override
  String get description => 'Remove the TOTP secret.';

  @override
  Future<int> run() async {
    final path = argResults!.option('config')!;
    if (!File(path).existsSync()) {
      err.writeln('$path not found.');
      return 66;
    }
    setTomlValue(path, 'auth', 'totp_secret', '""');
    out
      ..writeln('TOTP disabled.')
      ..writeln(_restartHint);
    return 0;
  }
}
