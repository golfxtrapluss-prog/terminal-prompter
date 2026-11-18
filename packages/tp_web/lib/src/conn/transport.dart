import 'dart:typed_data';

/// A frame received from the agent.
sealed class ServerFrame {
  const ServerFrame();
}

/// JSON control message.
final class TextServerFrame extends ServerFrame {
  const TextServerFrame(this.text);

  /// The JSON text.
  final String text;
}

/// Binary terminal-data frame.
final class BinaryServerFrame extends ServerFrame {
  const BinaryServerFrame(this.bytes);

  /// Raw frame bytes.
  final Uint8List bytes;
}

/// One connection attempt to the agent (WebSocket now, SSE in M6).
/// Platform-neutral so the connection engine can be tested on the VM.
abstract interface class ClientTransport {
  /// Completes when the transport is usable; fails if it never opens.
  Future<void> get opened;

  /// Frames from the agent; ends when the connection closes.
  Stream<ServerFrame> get frames;

  /// True while open.
  bool get isOpen;

  /// Close code once closed (4401 = login ended), else null.
  int? get closeCode;

  /// Sends a JSON control message.
  void sendText(String text);

  /// Sends a binary frame.
  void sendBinary(Uint8List bytes);

  /// Closes the connection.
  void close();
}

/// Creates a transport for [url]; one per connection attempt.
typedef TransportFactory = ClientTransport Function(String url);

/// Minimal key/value persistence (localStorage in the browser).
abstract interface class KeyValueStore {
  /// Reads [key] or null.
  String? read(String key);

  /// Writes [key].
  void write(String key, String value);

  /// Removes [key].
  void remove(String key);
}

/// In-memory [KeyValueStore] for tests and storage-less environments.
final class MemoryStore implements KeyValueStore {
  final Map<String, String> _map = {};

  @override
  String? read(String key) => _map[key];

  @override
  void write(String key, String value) => _map[key] = value;

  @override
  void remove(String key) => _map.remove(key);
}
