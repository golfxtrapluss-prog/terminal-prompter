import 'package:args/command_runner.dart';

/// `tp-agent run`: starts the service.
///
/// Milestone M0 only wires the options; the server itself lands in M2.
final class RunCommand extends Command<int> {
  /// Creates the command writing to [out] and [err].
  RunCommand({required StringSink out, required StringSink err})
    : _out = out,
      _err = err {
    argParser
      ..addOption(
        'config',
        abbr: 'c',
        help: 'Path to config.toml.',
        defaultsTo: '/etc/tp-agent/config.toml',
      )
      ..addOption(
        'dev-web-dir',
        help:
            'Serve the web client from this directory instead of the '
            'embedded files (development only).',
      );
  }

  // Kept for the server implementation in M2; unused until then.
  // ignore: unused_field
  final StringSink _out;
  final StringSink _err;

  @override
  String get name => 'run';

  @override
  String get description => 'Start the agent.';

  @override
  Future<int> run() async {
    final configPath = argResults!.option('config');
    _err.writeln(
      'tp-agent run: not implemented yet (roadmap milestone M2). '
      'Would load $configPath.',
    );
    return 2;
  }
}
