import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

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

/// Browser WebSocket transport (`binaryType = arraybuffer`).
final class WsClientTransport {
  /// Opens a WebSocket to [url].
  WsClientTransport(String url) : _socket = web.WebSocket(url) {
    _socket.binaryType = 'arraybuffer';
    _socket.onopen = ((web.Event _) {
      if (!_opened.isCompleted) _opened.complete();
    }).toJS;
    _socket.onmessage = ((web.MessageEvent event) {
      final data = event.data;
      if (data.isA<JSString>()) {
        _frames.add(TextServerFrame((data as JSString).toDart));
      } else if (data.isA<JSArrayBuffer>()) {
        final buffer = (data as JSArrayBuffer).toDart;
        _frames.add(BinaryServerFrame(buffer.asUint8List()));
      }
    }).toJS;
    _socket.onerror = ((web.Event _) {
      if (!_opened.isCompleted) {
        _opened.completeError(StateError('WebSocket error'));
      }
    }).toJS;
    _socket.onclose = ((web.CloseEvent event) {
      _closeCode = event.code;
      if (!_opened.isCompleted) {
        _opened.completeError(StateError('WebSocket closed (${event.code})'));
      }
      unawaited(_frames.close());
    }).toJS;
  }

  final web.WebSocket _socket;
  final Completer<void> _opened = Completer<void>();
  final StreamController<ServerFrame> _frames = StreamController<ServerFrame>();
  int? _closeCode;

  /// Completes when the socket is open; fails if it never opens.
  Future<void> get opened => _opened.future;

  /// Frames from the agent; ends when the socket closes.
  Stream<ServerFrame> get frames => _frames.stream;

  /// WebSocket close code once closed.
  int? get closeCode => _closeCode;

  /// True while the socket is open.
  bool get isOpen => _socket.readyState == web.WebSocket.OPEN;

  /// Sends a JSON control message.
  void sendText(String text) {
    if (isOpen) _socket.send(text.toJS);
  }

  /// Sends a binary frame.
  void sendBinary(Uint8List bytes) {
    if (isOpen) _socket.send(bytes.toJS);
  }

  /// Closes the socket.
  void close() => _socket.close();
}
