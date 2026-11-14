import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:logging/logging.dart';

import '../config/config.dart';
import '../generated/assets.g.dart';
import '../log.dart';
import '../server/agent_server.dart';
import '../server/static_files.dart';
import '../session/session_manager.dart';
import '../version.dart';

/// `tp-agent run`: starts the service and runs until SIGINT/SIGTERM.
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
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        help: 'Log at debug level.',
        negatable: false,
      );
  }

  final StringSink _out;
  final StringSink _err;

  @override
  String get name => 'run';

  @override
  String get description => 'Start the agent.';

  @override
  Future<int> run() async {
    final results = argResults!;
    installJsonLogging(
      level: results.flag('verbose') ? Level.FINE : Level.INFO,
    );
    final log = Logger('agent');

    final AgentConfig config;
    try {
      config = await AgentConfig.load(results.option('config')!);
    } on ConfigError catch (e) {
      _err.writeln('tp-agent: $e');
      return 78; // EX_CONFIG
    }

    final devWebDir = results.option('dev-web-dir');
    final staticFiles = devWebDir != null
        ? DirectoryStaticFiles(devWebDir)
        : EmbeddedStaticFiles(embeddedAssets);
    if (devWebDir == null && embeddedAssets.isEmpty) {
      log.warning({
        'msg': 'no_embedded_assets',
        'hint': 'run make embed or pass --dev-web-dir',
      });
    }

    final sessions = SessionManager(config: config)..start();
    final server = AgentServer(
      config: config,
      sessions: sessions,
      staticFiles: staticFiles,
      agentVersion: tpVersion,
    );
    try {
      await server.start();
    } on SocketException catch (e) {
      _err.writeln(
        'tp-agent: cannot listen on ${config.listenHost}:${config.listenPort}: ${e.message}',
      );
      return 1;
    }
    _out.writeln(
      'tp-agent $tpVersion listening on '
      'http://${config.listenHost}:${server.port}${config.basePath}',
    );

    final stop = Completer<ProcessSignal>();
    final subscriptions = [
      for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm])
        signal.watch().listen((s) {
          if (!stop.isCompleted) stop.complete(s);
        }),
    ];
    final signal = await stop.future;
    for (final s in subscriptions) {
      await s.cancel();
    }
    log.info({'msg': 'stopping', 'signal': signal.name});
    await server.stop();
    await sessions.shutdown();
    return 0;
  }
}
