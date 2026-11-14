/// Terminal Prompter agent library.
///
/// `bin/tp_agent.dart` is a thin wrapper around [buildRunner] so the CLI can be
/// exercised in tests with captured output.
library;

export 'src/cli/runner.dart';
export 'src/pty/errors.dart';
export 'src/pty/pty_process.dart';
export 'src/session/ring_buffer.dart';
export 'src/version.dart';
