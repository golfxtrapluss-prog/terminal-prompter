import 'package:args/command_runner.dart';

import '../auth/password.dart';
import 'auth_commands.dart';
import 'console.dart';
import 'run_command.dart';
import 'version_command.dart';

/// Builds the `tp-agent` command-line interface.
///
/// All command output goes to [out] and [err] instead of `stdout`/`stderr`
/// directly, and answers come from [console], so tests can capture and
/// script it. [cost] lets tests use cheap argon2id parameters.
CommandRunner<int> buildRunner({
  required StringSink out,
  required StringSink err,
  Console console = const StdConsole(),
  Argon2Cost cost = Argon2Cost.password,
}) {
  return CommandRunner<int>(
      'tp-agent',
      'Terminal Prompter agent: a real terminal in the browser over HTTPS/443.',
    )
    ..addCommand(VersionCommand(out))
    ..addCommand(RunCommand(out: out, err: err))
    ..addCommand(InitCommand(out: out, err: err, console: console, cost: cost))
    ..addCommand(
      PasswdCommand(out: out, err: err, console: console, cost: cost),
    )
    ..addCommand(TotpCommand(out: out, err: err, console: console));
}
