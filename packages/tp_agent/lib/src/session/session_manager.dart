import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:tp_protocol/tp_protocol.dart';

import '../audit/audit_log.dart';
import '../config/config.dart';
import '../pty/pty_process.dart';
import 'session.dart';

/// Errors from session management, mapped to protocol error codes.
sealed class SessionError implements Exception {
  const SessionError(this.message);

  /// Description.
  final String message;

  /// Protocol error code.
  ErrorCode get code;

  @override
  String toString() => 'SessionError: $message';
}

/// `sessions.max` reached.
final class SessionLimitError extends SessionError {
  const SessionLimitError(int max) : super('session limit ($max) reached');

  @override
  ErrorCode get code => ErrorCode.sessionLimit;
}

/// No such session.
final class SessionNotFoundError extends SessionError {
  SessionNotFoundError(SessionId id) : super('session $id not found');

  @override
  ErrorCode get code => ErrorCode.sessionNotFound;
}

/// Owns all sessions: creation, lookup, idle/exited clean-up and shutdown.
final class SessionManager {
  /// Creates a manager for [config].
  SessionManager({
    required this.config,
    DateTime Function()? clock,
    Map<String, String>? environment,
    AuditLog? audit,
  }) : audit = audit ?? AuditLog.disabled(),
       _clock = clock ?? DateTime.now,
       _environment = environment ?? Platform.environment;

  /// How long an exited session stays listed before it is removed.
  static const Duration exitedRetention = Duration(hours: 1);

  /// Agent configuration.
  final AgentConfig config;

  /// Audit log for session start/end.
  final AuditLog audit;

  final DateTime Function() _clock;
  final Map<String, String> _environment;
  final Map<SessionId, Session> _sessions = {};
  final Logger _log = Logger('sessions');
  Timer? _sweeper;
  int _counter = 0;

  /// All sessions, including exited ones not yet removed.
  Iterable<Session> get sessions => _sessions.values;

  /// Number of sessions whose process is still running.
  int get liveCount => _sessions.values.where((s) => s.exited == null).length;

  /// Looks up a session.
  Session? get(SessionId id) => _sessions[id];

  /// Looks up a session or throws [SessionNotFoundError].
  Session require(SessionId id) =>
      _sessions[id] ?? (throw SessionNotFoundError(id));

  /// Summaries of all sessions, newest first.
  List<SessionInfo> list() {
    final infos = [for (final s in _sessions.values) s.info];
    infos.sort((a, b) => b.created.compareTo(a.created));
    return infos;
  }

  /// Starts a new shell session.
  Future<Session> create({
    required String name,
    required int cols,
    required int rows,
  }) async {
    if (liveCount >= config.sessions.max) {
      throw SessionLimitError(config.sessions.max);
    }
    final id = SessionId.random();
    final shell = config.shell;
    final (command, arguments) = _resolveCommand(shell, id);
    final pty = await PtyProcess.start(
      command: command,
      arguments: arguments,
      environment: shell.env,
      workingDirectory: _resolveWorkdir(shell.workdir),
      cols: cols,
      rows: rows,
    );
    _counter++;
    final session = Session(
      id: id,
      name: name.isEmpty ? 'Session $_counter' : name,
      pty: pty,
      scrollbackBytes: config.sessions.scrollbackBytes,
      coalesce: config.transport.outputCoalesce,
      clock: _clock,
    );
    _sessions[id] = session;
    _log.info({
      'msg': 'session_start',
      'sid': '$id',
      'name': session.name,
      'pid': pty.pid,
    });
    audit.record('session_start', {'sid': '$id', 'name': session.name});
    unawaited(
      pty.exited.then((info) {
        _log.info({'msg': 'session_exit', 'sid': '$id', 'exit': '$info'});
        audit.record('session_end', {
          'sid': '$id',
          'reason': 'exit',
          'exit': '$info',
        });
      }),
    );
    return session;
  }

  /// Ends and removes a session.
  Future<void> kill(SessionId id) async {
    final session = require(id);
    await session.terminate();
    _sessions.remove(id);
    _log.info({'msg': 'session_kill', 'sid': '$id'});
    audit.record('session_end', {'sid': '$id', 'reason': 'killed'});
  }

  /// Starts periodic clean-up of idle and exited sessions.
  void start() {
    _sweeper ??= Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(sweep());
    });
  }

  /// Removes exited sessions older than [exitedRetention] and ends sessions
  /// idle longer than `sessions.idle_timeout` with no client attached.
  Future<void> sweep() async {
    final now = _clock();
    for (final session in _sessions.values.toList()) {
      final exitedAt = session.exitedAt;
      if (exitedAt != null) {
        if (now.difference(exitedAt) >= exitedRetention) {
          await session.close();
          _sessions.remove(session.id);
          _log.info({'msg': 'session_expired', 'sid': '${session.id}'});
        }
        continue;
      }
      if (session.clients == 0 &&
          now.difference(session.lastSeen) >= config.sessions.idleTimeout) {
        _log.info({'msg': 'session_idle_timeout', 'sid': '${session.id}'});
        await kill(session.id);
      }
    }
  }

  /// Stops clean-up and ends every session.
  Future<void> shutdown() async {
    _sweeper?.cancel();
    _sweeper = null;
    for (final session in _sessions.values.toList()) {
      await session.terminate(grace: const Duration(seconds: 1));
    }
    _sessions.clear();
  }

  static (String, List<String>) _resolveCommand(
    ShellConfig shell,
    SessionId id,
  ) {
    switch (shell.wrap) {
      case ShellWrap.none:
        return (shell.command, shell.args);
      case ShellWrap.tmux:
        final inner = [shell.command, ...shell.args].join(' ');
        return ('tmux', ['new-session', '-A', '-s', 'tp-$id', inner]);
    }
  }

  String _resolveWorkdir(String workdir) {
    final home = _environment['HOME'] ?? '/';
    var path = workdir;
    if (path == '~') {
      path = home;
    } else if (path.startsWith('~/')) {
      path = '$home${path.substring(1)}';
    }
    if (!Directory(path).existsSync()) {
      _log.warning({'msg': 'workdir_missing', 'path': path, 'fallback': '/'});
      return '/';
    }
    return path;
  }
}
