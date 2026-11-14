import 'package:args/command_runner.dart';

import 'run_command.dart';
import 'version_command.dart';

/// Builds the `tp-agent` command-line interface.
///
/// All command output goes to [out] and [err] instead of `stdout`/`stderr`
/// directly, so tests can capture it.
CommandRunner<int> buildRunner({
  required StringSink out,
  required StringSink err,
}) {
  return CommandRunner<int>(
      'tp-agent',
      'Terminal Prompter agent: a real terminal in the browser over HTTPS/443.',
    )
    ..addCommand(VersionCommand(out))
    ..addCommand(RunCommand(out: out, err: err));
}
