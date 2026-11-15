import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'transport.dart';

/// Browser WebSocket transport (`binaryType = arraybuffer`).
final class WsClientTransport implements ClientTransport {
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
      closeCode = event.code;
      if (!_opened.isCompleted) {
        _opened.completeError(StateError('WebSocket closed (${event.code})'));
      }
      unawaited(_frames.close());
    }).toJS;
  }

  final web.WebSocket _socket;
  final Completer<void> _opened = Completer<void>();
  final StreamController<ServerFrame> _frames = StreamController<ServerFrame>();

  /// WebSocket close code once closed.
  int? closeCode;

  @override
  Future<void> get opened => _opened.future;

  @override
  Stream<ServerFrame> get frames => _frames.stream;

  @override
  bool get isOpen => _socket.readyState == web.WebSocket.OPEN;

  @override
  void sendText(String text) {
    if (isOpen) _socket.send(text.toJS);
  }

  @override
  void sendBinary(Uint8List bytes) {
    if (isOpen) _socket.send(bytes.toJS);
  }

  @override
  void close() => _socket.close();
}
