/// Protocol-wide limits shared by agent and client (docs/04, docs/05, docs/07).
///
/// Every boundary has a cap so a hostile or broken peer cannot exhaust memory.
abstract final class Limits {
  /// Maximum size of a JSON control message in either direction.
  static const int maxControlMessageBytes = 1024 * 1024;

  /// Maximum payload of one binary input frame.
  static const int maxInputFrameBytes = 1024 * 1024;

  /// Largest payload the server puts in one output frame.
  static const int maxOutputFrameBytes = 64 * 1024;

  /// Maximum unacknowledged terminal output the server keeps in flight per
  /// client before pausing sends (the PTY keeps filling the ring buffer).
  static const int maxUnackedOutputBytes = 2 * 1024 * 1024;

  /// The client acknowledges output at least every this many bytes...
  static const int ackEveryBytes = 64 * 1024;

  /// ...or at least this often while output is flowing.
  static const Duration ackInterval = Duration(milliseconds: 500);

  /// Heartbeat interval on both sides. Kept well under the 60 s idle cut-off
  /// used by many proxies.
  static const Duration heartbeat = Duration(seconds: 15);

  /// A connection with no traffic for this long is considered dead.
  static const Duration deadAfter = Duration(seconds: 30);

  /// Default ring-buffer capacity per session (`sessions.scrollback_bytes`).
  static const int defaultScrollbackBytes = 1024 * 1024;

  /// Maximum concurrent WebSocket connections per login session.
  static const int maxWebSocketsPerLogin = 10;

  /// Number of recent `client_msg_id`s the agent remembers per client for
  /// input idempotency.
  static const int inputIdHistory = 256;

  /// Length of a raw terminal-session id in bytes (128-bit random).
  static const int sessionIdBytes = 16;

  /// Maximum length of a session name.
  static const int maxSessionNameLength = 64;

  /// Maximum length of free-text fields such as `client`, `agent`, `msg`.
  static const int maxTextLength = 1024;

  /// Maximum number of capability strings in `hello`.
  static const int maxCaps = 32;

  /// Maximum length of `hello.instance`.
  static const int maxInstanceIdLength = 64;

  /// A paused (non-acking) client whose resume point has left the ring
  /// buffer, or whose unacknowledged output exceeds this, is disconnected
  /// (docs/02 "Treg abonnent"); it resumes from `last_seq`.
  static const int slowConsumerDisconnectBytes = 4 * 1024 * 1024;

  /// Reconnect backoff schedule in seconds (docs/03), with jitter applied.
  static const List<double> backoffSeconds = [0.5, 1, 2, 4, 8, 10];

  /// Largest terminal dimension accepted in `attach`/`resize`.
  static const int maxDimension = 0xFFFF;
}

/// Layout of binary WebSocket frames carrying terminal data (docs/04).
///
/// ```text
/// byte 0      : type
/// byte 1..16  : session_id (16 raw bytes)
/// byte 17..24 : seq (uint64 big-endian) for output; client_msg_id for input
/// byte 25..   : data
/// ```
abstract final class BinaryFrame {
  /// Output from the PTY, server to client.
  static const int typeOutput = 0x01;

  /// Input to the PTY, client to server.
  static const int typeInput = 0x02;

  /// Output of a multi-server run (v2, relay mode only). Reserved; never reuse.
  static const int typeExecOut = 0x03;

  /// Fixed header size preceding the payload.
  static const int headerLength = 1 + Limits.sessionIdBytes + 8;
}

/// Capability strings exchanged in `hello.caps`.
abstract final class Caps {
  /// Terminal data travels in binary frames (always true for WebSocket).
  static const String binary = 'binary';

  /// The agent confirms delivered input with `ack_in`.
  static const String ackIn = 'ack_in';

  /// The agent offers the SSE fallback transport.
  static const String sse = 'sse';
}
