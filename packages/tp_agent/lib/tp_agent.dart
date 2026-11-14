/// Terminal Prompter agent library.
///
/// `bin/tp_agent.dart` is a thin wrapper around [buildRunner] so the CLI can be
/// exercised in tests with captured output.
library;

export 'src/cli/runner.dart';
export 'src/config/config.dart';
export 'src/pty/errors.dart';
export 'src/pty/pty_process.dart';
export 'src/server/agent_server.dart';
export 'src/server/static_files.dart';
export 'src/session/ring_buffer.dart';
export 'src/session/session.dart';
export 'src/session/session_manager.dart';
export 'src/transport/client_connection.dart';
export 'src/transport/transport.dart';
export 'src/transport/ws_transport.dart';
export 'src/version.dart';
