/// Protocol-wide limits shared by agent and client (docs/04, docs/05, docs/07).
///
/// Every boundary has a cap so a hostile or broken peer cannot exhaust memory.
abstract final class Limits {
  /// Maximum size of a JSON control message in either direction.
  static const int maxControlMessageBytes = 1024 * 1024;

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
