import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tp_protocol/tp_protocol.dart';

import 'transport.dart';

/// Server-Sent Events fallback for networks that block WebSocket upgrades
/// (docs/04 "SSE-fallback", ADR-007).
///
/// The event stream carries exactly what a WebSocket would: `event: ctl`
/// with a JSON control message, and `event: out` with an output frame as
/// `{"s": session, "seq": n, "d": base64}`. The client sends its messages
/// with `POST /api/sse/send?stream=<id>` (see [deliver]). The first event is
/// `ctl {"t":"sse_open","stream":"<id>"}`.
final class SseTransport implements Transport {
  SseTransport(
    this._response, {
    required this.id,
    required this.peer,
    required Duration heartbeat,
    this.loginHash,
  }) : _heartbeat = heartbeat;

  /// Padding so buffering proxies flush the first event (docs/07).
  static const int initialPadding = 2048;

  final HttpResponse _response;
  final Duration _heartbeat;

  /// Random stream id the client must quote when posting.
  final String id;

  /// Login that opened the stream; posts from another login are refused.
  final String? loginHash;

  @override
  final String peer;

  final StreamController<TransportFrame> _frames =
      StreamController<TransportFrame>();
  final Completer<void> _done = Completer<void>();
  Timer? _timer;
  bool _closed = false;

  @override
  Stream<TransportFrame> get frames => _frames.stream;

  @override
  Future<void> get done => _done.future;

  /// Sends headers, padding and the `sse_open` event; then keeps the stream
  /// alive with comment lines.
  void start() {
    _response
      ..statusCode = HttpStatus.ok
      ..bufferOutput = false
      ..headers.set(
        HttpHeaders.contentTypeHeader,
        'text/event-stream; charset=utf-8',
      )
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store, no-transform')
      ..headers.set('X-Accel-Buffering', 'no');
    _response.headers.chunkedTransferEncoding = true;
    _write(': ${' ' * initialPadding}\n\n');
    sendText(jsonEncode({'t': 'sse_open', 'stream': id}));
    _timer = Timer.periodic(_heartbeat, (_) => _write(': hb\n\n'));
    unawaited(
      _response.done.then(
        (_) => _shutdown(),
        onError: (Object _) => _shutdown(),
      ),
    );
  }

  @override
  void sendText(String text) => _write('event: ctl\ndata: $text\n\n');

  @override
  void sendBinary(Uint8List bytes) {
    final frame = decodeBinaryFrame(bytes);
    if (frame is! OutputFrame) return;
    final data = jsonEncode({
      's': '${frame.session}',
      'seq': frame.seq,
      'd': base64Encode(frame.data),
    });
    _write('event: out\ndata: $data\n\n');
  }

  /// Feeds one POST body (a JSON array) into [frames]. Control messages are
  /// passed on as JSON text; `{"t":"in","session","id","d","p"?}` becomes a
  /// binary input frame (`p: true` = from the Prompter, type 0x04).
  void deliver(List<Object?> messages) {
    if (_closed) return;
    for (final m in messages) {
      if (m is! Map<String, Object?>) {
        throw const ProtocolException('SSE message must be an object');
      }
      if (m['t'] == 'in') {
        final session = SessionId.tryParse(
          m['session'] is String ? m['session']! as String : '',
        );
        final id = m['id'];
        final d = m['d'];
        if (session == null || id is! int || id < 0 || d is! String) {
          throw const ProtocolException('bad SSE input message');
        }
        final Uint8List data;
        try {
          data = base64Decode(d);
        } on FormatException {
          throw const ProtocolException('bad base64 in SSE input');
        }
        _frames.add(
          BinaryDataFrame(
            encodeInputFrame(session, id, data, fromPrompter: m['p'] == true),
          ),
        );
      } else {
        _frames.add(TextFrame(jsonEncode(m)));
      }
    }
  }

  @override
  Future<void> close({int code = 1000, String reason = ''}) async {
    if (!_closed) {
      // Tell the client why (WebSocket close codes have no SSE equivalent).
      _write(
        'event: ctl\ndata: ${jsonEncode({'t': 'sse_close', 'code': code, 'reason': reason})}\n\n',
      );
    }
    _shutdown();
    try {
      await _response.close();
    } on Object {
      // Client already gone.
    }
  }

  void _write(String text) {
    if (_closed) return;
    try {
      _response.write(text);
    } on Object {
      _shutdown();
    }
  }

  void _shutdown() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    unawaited(_frames.close());
    if (!_done.isCompleted) _done.complete();
  }
}
