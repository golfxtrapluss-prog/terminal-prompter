import 'dart:io';
import 'dart:typed_data';

import 'transport.dart';

/// [Transport] over a `dart:io` WebSocket.
final class WsTransport implements Transport {
  /// Wraps an upgraded [socket].
  WsTransport(this._socket, {required this.peer});

  final WebSocket _socket;

  @override
  final String peer;

  @override
  Stream<TransportFrame> get frames => _socket.map((Object? event) {
    return switch (event) {
      final String text => TextFrame(text),
      final Uint8List bytes => BinaryDataFrame(bytes),
      final List<int> bytes => BinaryDataFrame(Uint8List.fromList(bytes)),
      _ => throw StateError('unexpected WebSocket event $event'),
    };
  });

  @override
  void sendText(String text) {
    if (_socket.readyState == WebSocket.open) _socket.add(text);
  }

  @override
  void sendBinary(Uint8List bytes) {
    if (_socket.readyState == WebSocket.open) _socket.add(bytes);
  }

  @override
  Future<void> close({int code = 1000, String reason = ''}) =>
      _socket.close(code, reason);

  @override
  Future<void> get done => _socket.done;
}
