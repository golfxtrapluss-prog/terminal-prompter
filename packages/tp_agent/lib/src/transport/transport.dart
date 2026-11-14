import 'dart:typed_data';

/// One frame received from a client.
sealed class TransportFrame {
  const TransportFrame();
}

/// A JSON control message.
final class TextFrame extends TransportFrame {
  const TextFrame(this.text);

  /// The JSON text.
  final String text;
}

/// A binary terminal-data frame.
final class BinaryDataFrame extends TransportFrame {
  const BinaryDataFrame(this.bytes);

  /// Raw frame bytes.
  final Uint8List bytes;
}

/// A bidirectional connection to one client, independent of whether it is a
/// WebSocket or the SSE fallback (docs/01 principle 4, ADR-007).
abstract interface class Transport {
  /// Frames from the client. Single subscription; ends when the peer closes.
  Stream<TransportFrame> get frames;

  /// Sends a JSON control message.
  void sendText(String text);

  /// Sends a binary frame.
  void sendBinary(Uint8List bytes);

  /// Closes the connection.
  Future<void> close({int code = 1000, String reason = ''});

  /// Completes when the connection is closed by either side.
  Future<void> get done;

  /// Description of the peer for logs, e.g. `203.0.113.9:51234`.
  String get peer;
}
