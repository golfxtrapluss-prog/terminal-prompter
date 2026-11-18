import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:tp_protocol/tp_protocol.dart';
import 'package:web/web.dart' as web;

import '../api_client.dart';
import 'transport.dart';

/// Server-Sent Events fallback (docs/04): an `EventSource` for everything
/// from the agent, and ordered `fetch` POSTs for everything to it. Presents
/// the same frames as the WebSocket transport, so the connection engine and
/// protocol code are unchanged.
final class SseClientTransport implements ClientTransport {
  /// Opens `<base>api/sse`.
  SseClientTransport(this.base) {
    _source = web.EventSource('${base}api/sse');
    _source.addEventListener(
      'ctl',
      ((web.MessageEvent e) => _onCtl((e.data as JSString).toDart)).toJS,
    );
    _source.addEventListener(
      'out',
      ((web.MessageEvent e) => _onOut((e.data as JSString).toDart)).toJS,
    );
    // EventSource would reconnect on its own; the connection engine owns
    // reconnecting (backoff, resume), so any error ends this transport.
    _source.onerror = ((web.Event _) => _finish(null)).toJS;
  }

  final String base;
  late final web.EventSource _source;
  final Completer<void> _opened = Completer<void>();
  final StreamController<ServerFrame> _frames = StreamController<ServerFrame>();
  final List<Object?> _queue = [];
  String? _stream;
  bool _sending = false;
  bool _closed = false;

  @override
  int? closeCode;

  @override
  Future<void> get opened => _opened.future;

  @override
  Stream<ServerFrame> get frames => _frames.stream;

  @override
  bool get isOpen => _stream != null && !_closed;

  @override
  void sendText(String text) => _enqueue(jsonDecode(text));

  @override
  void sendBinary(Uint8List bytes) {
    final frame = decodeBinaryFrame(bytes);
    if (frame is! InputFrame) return;
    _enqueue({
      't': 'in',
      'session': '${frame.session}',
      'id': frame.clientMsgId,
      'd': base64Encode(frame.data),
      if (frame.fromPrompter) 'p': true,
    });
  }

  @override
  void close() => _finish(1000);

  void _onCtl(String data) {
    final Object? json;
    try {
      json = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (json is Map<String, Object?>) {
      if (json['t'] == 'sse_open') {
        _stream = json['stream'] as String?;
        if (!_opened.isCompleted) _opened.complete();
        _flush();
        return;
      }
      if (json['t'] == 'sse_close') {
        _finish(json['code'] as int?);
        return;
      }
    }
    _frames.add(TextServerFrame(data));
  }

  void _onOut(String data) {
    final json = jsonDecode(data) as Map<String, Object?>;
    final session = SessionId.tryParse(json['s'] as String? ?? '');
    final seq = json['seq'];
    final d = json['d'];
    if (session == null || seq is! int || d is! String) return;
    _frames.add(
      BinaryServerFrame(encodeOutputFrame(session, seq, base64Decode(d))),
    );
  }

  void _enqueue(Object? message) {
    if (_closed) return;
    _queue.add(message);
    // Batch everything queued in this event-loop turn into one POST.
    scheduleMicrotask(_flush);
  }

  Future<void> _flush() async {
    if (_sending || _queue.isEmpty || _stream == null || _closed) return;
    _sending = true;
    final batch = List<Object?>.of(_queue);
    _queue.clear();
    try {
      final headers = web.Headers()..set('Content-Type', 'application/json');
      final csrf = ApiClient.csrfToken();
      if (csrf != null) headers.set('X-TP-CSRF', csrf);
      final response = await web.window
          .fetch(
            '${base}api/sse/send?stream=$_stream'.toJS,
            web.RequestInit(
              method: 'POST',
              headers: headers,
              body: jsonEncode(batch).toJS,
              credentials: 'same-origin',
            ),
          )
          .toDart;
      if (!response.ok) {
        _finish(response.status == 401 ? 4401 : 1011);
        return;
      }
    } on Object {
      _finish(1006);
      return;
    } finally {
      _sending = false;
    }
    if (_queue.isNotEmpty) unawaited(_flush());
  }

  void _finish(int? code) {
    if (_closed) return;
    _closed = true;
    closeCode = code;
    _source.close();
    if (!_opened.isCompleted) _opened.completeError(StateError('SSE failed'));
    unawaited(_frames.close());
  }
}
