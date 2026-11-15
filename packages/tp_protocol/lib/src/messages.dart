import 'session_id.dart';

/// Signals a client can ask the agent to deliver to a session (docs/04).
enum TerminalSignal {
  /// Ctrl-C: `\x03` is written to the terminal.
  interrupt('INT'),

  /// `SIGTERM` to the session's process group.
  terminate('TERM'),

  /// `SIGKILL` to the whole session.
  kill('KILL'),

  /// Ctrl-Z: `\x1a` is written to the terminal.
  suspend('TSTP'),

  /// Ctrl-D: `\x04` is written to the terminal.
  eof('EOF');

  const TerminalSignal(this.wire);

  /// Name used on the wire.
  final String wire;

  /// Looks up a signal by its wire name.
  static TerminalSignal? fromWire(String wire) {
    for (final s in values) {
      if (s.wire == wire) return s;
    }
    return null;
  }
}

/// Error codes carried by [ErrorMessage] (docs/04).
enum ErrorCode {
  /// Cookie missing or expired; the client shows the login page.
  authRequired('auth_required'),

  /// No session with the given id.
  sessionNotFound('session_not_found'),

  /// `sessions.max` reached.
  sessionLimit('session_limit'),

  /// The message could not be decoded or failed validation.
  badMessage('bad_message'),

  /// Client protocol version not supported; reload the page.
  versionMismatch('version_mismatch'),

  /// Too many requests.
  rateLimited('rate_limited'),

  /// Unexpected server-side failure.
  internal('internal'),

  /// Feature reserved for a later version (for example `exec_*`).
  unsupported('unsupported');

  const ErrorCode(this.wire);

  /// Name used on the wire.
  final String wire;

  /// Looks up a code by its wire name.
  static ErrorCode? fromWire(String wire) {
    for (final c in values) {
      if (c.wire == wire) return c;
    }
    return null;
  }
}

/// How a session's process ended.
final class ExitStatus {
  /// Creates the status; one of [code] or [signal] is set.
  const ExitStatus({this.code, this.signal});

  /// Exit code when the process exited normally.
  final int? code;

  /// Signal number when the process was killed.
  final int? signal;
}

/// Summary of a session as listed in `hello` and `sessions`.
final class SessionInfo {
  /// Creates the summary.
  const SessionInfo({
    required this.id,
    required this.name,
    required this.created,
    required this.lastSeen,
    required this.clients,
    this.exited,
  });

  /// Session id.
  final SessionId id;

  /// Human-readable name.
  final String name;

  /// When the session was created.
  final DateTime created;

  /// Last input or attach.
  final DateTime lastSeen;

  /// Number of clients currently attached.
  final int clients;

  /// Set once the process has ended.
  final ExitStatus? exited;
}

/// Base of every JSON control message.
abstract interface class ProtocolMessage {
  /// Value of the `t` field.
  String get type;
}

/// Control messages sent by the client.
sealed class ClientMessage implements ProtocolMessage {
  const ClientMessage();
}

/// First message on a connection.
final class ClientHello extends ClientMessage {
  /// Creates the message.
  const ClientHello({
    required this.version,
    required this.client,
    this.caps = const [],
    this.instance,
  });

  /// Protocol version the client speaks.
  final int version;

  /// Client build identifier.
  final String client;

  /// Capability strings, see `Caps`.
  final List<String> caps;

  /// Random id of this client instance (browser tab). Input idempotency is
  /// tracked per instance so resends after a reconnect are deduplicated.
  final String? instance;

  @override
  String get type => 'hello';
}

/// Attach to an existing session, or create one when [session] is null.
final class Attach extends ClientMessage {
  /// Creates the message.
  const Attach({
    required this.cols,
    required this.rows,
    this.session,
    this.name,
    this.lastSeq,
  });

  /// Existing session id, or null to create a new one.
  final SessionId? session;

  /// Name for a new session.
  final String? name;

  /// Terminal width.
  final int cols;

  /// Terminal height.
  final int rows;

  /// Resume output from this sequence number (bytes already seen).
  final int? lastSeq;

  @override
  String get type => 'attach';
}

/// Stop receiving output from a session without ending it.
final class Detach extends ClientMessage {
  /// Creates the message.
  const Detach(this.session);

  /// Session id.
  final SessionId session;

  @override
  String get type => 'detach';
}

/// Change a session's terminal size.
final class Resize extends ClientMessage {
  /// Creates the message.
  const Resize({required this.session, required this.cols, required this.rows});

  /// Session id.
  final SessionId session;

  /// Terminal width.
  final int cols;

  /// Terminal height.
  final int rows;

  @override
  String get type => 'resize';
}

/// Deliver a signal to a session.
final class SignalMessage extends ClientMessage {
  /// Creates the message.
  const SignalMessage({required this.session, required this.signal});

  /// Session id.
  final SessionId session;

  /// Which signal.
  final TerminalSignal signal;

  @override
  String get type => 'signal';
}

/// Acknowledge output received up to [seq] (flow control and resume).
final class Ack extends ClientMessage {
  /// Creates the message.
  const Ack({required this.session, required this.seq});

  /// Session id.
  final SessionId session;

  /// Next sequence number the client expects.
  final int seq;

  @override
  String get type => 'ack';
}

/// End a session and its processes.
final class KillSession extends ClientMessage {
  /// Creates the message.
  const KillSession(this.session);

  /// Session id.
  final SessionId session;

  @override
  String get type => 'kill';
}

/// Rename a session.
final class Rename extends ClientMessage {
  /// Creates the message.
  const Rename({required this.session, required this.name});

  /// Session id.
  final SessionId session;

  /// New name.
  final String name;

  @override
  String get type => 'rename';
}

/// Request the session list.
final class ListSessions extends ClientMessage {
  /// Creates the message.
  const ListSessions();

  @override
  String get type => 'list';
}

/// Latency probe; the server echoes [ts] in `pong`.
final class Ping extends ClientMessage {
  /// Creates the message.
  const Ping(this.ts);

  /// Client timestamp (milliseconds).
  final int ts;

  @override
  String get type => 'ping';
}

/// Control messages sent by the server.
sealed class ServerMessage implements ProtocolMessage {
  const ServerMessage();
}

/// Reply to [ClientHello].
final class ServerHello extends ServerMessage {
  /// Creates the message.
  const ServerHello({
    required this.version,
    required this.agent,
    required this.host,
    this.caps = const [],
    this.sessions = const [],
  });

  /// Protocol version the server speaks.
  final int version;

  /// Agent build identifier.
  final String agent;

  /// Server hostname.
  final String host;

  /// Capability strings, see `Caps`.
  final List<String> caps;

  /// Existing sessions.
  final List<SessionInfo> sessions;

  @override
  String get type => 'hello';
}

/// Reply to [Attach]; replay follows as binary output frames.
final class Attached extends ServerMessage {
  /// Creates the message.
  const Attached({
    required this.session,
    required this.name,
    required this.seq,
    required this.cols,
    required this.rows,
    this.truncated,
  });

  /// Session id.
  final SessionId session;

  /// Session name.
  final String name;

  /// Current sequence number (next byte the session will produce).
  final int seq;

  /// Terminal width.
  final int cols;

  /// Terminal height.
  final int rows;

  /// Bytes in `[from, to)` were lost because the scrollback was overwritten.
  final ({int from, int to})? truncated;

  @override
  String get type => 'attached';
}

/// Session list, sent on request or when the list changes.
final class SessionsMessage extends ServerMessage {
  /// Creates the message.
  const SessionsMessage(this.sessions);

  /// The sessions.
  final List<SessionInfo> sessions;

  @override
  String get type => 'sessions';
}

/// A session's process ended.
final class SessionExit extends ServerMessage {
  /// Creates the message.
  const SessionExit({required this.session, required this.status});

  /// Session id.
  final SessionId session;

  /// How it ended.
  final ExitStatus status;

  @override
  String get type => 'exit';
}

/// Reply to [Ping].
final class Pong extends ServerMessage {
  /// Creates the message.
  const Pong(this.ts);

  /// The client's timestamp echoed back.
  final int ts;

  @override
  String get type => 'pong';
}

/// Input frame with `client_msg_id` [id] was written to the PTY.
final class AckIn extends ServerMessage {
  /// Creates the message.
  const AckIn({required this.session, required this.id});

  /// Session id.
  final SessionId session;

  /// The acknowledged `client_msg_id`.
  final int id;

  @override
  String get type => 'ack_in';
}

/// Something went wrong.
final class ErrorMessage extends ServerMessage {
  /// Creates the message.
  const ErrorMessage({required this.code, required this.msg, this.session});

  /// Machine-readable code.
  final ErrorCode code;

  /// Human-readable description.
  final String msg;

  /// Related session, if any.
  final SessionId? session;

  @override
  String get type => 'error';
}

/// Informational message for the user, e.g. "agent updated, reload".
final class Notice extends ServerMessage {
  /// Creates the message.
  const Notice({required this.level, required this.msg});

  /// `info`, `warning` or `error`.
  final String level;

  /// Text to show.
  final String msg;

  @override
  String get type => 'notice';
}
