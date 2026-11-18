import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tp_protocol/tp_protocol.dart';

/// Minimal SSE client for tests: GET /api/sse, parse events, POST messages
/// to /api/sse/send in order. Mirrors what the web client does.
final class SseTestClient {
  SseTestClient(this.base);

  final Uri base;
  final HttpClient http = HttpClient();
  final List<ServerMessage> inbox = [];
  final StringBuffer output = StringBuffer();
  final List<OutputFrame> frames = [];
  final Map<String, String> headers = {};
  String? stream;
  int? lastSeq;
  int nextId = 1;
  bool closed = false;
  int? closeCode;
  Future<void> _sendChain = Future.value();

  Future<void> connect() async {
    final req = await http.getUrl(base.resolve('api/sse'));
    headers.forEach(req.headers.set);
    final res = await req.close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('SSE status ${res.statusCode}');
    }
    final opened = Completer<void>();
    var event = 'message';
    final data = StringBuffer();
    res
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.isEmpty) {
              _dispatch(event, data.toString(), opened);
              event = 'message';
              data.clear();
            } else if (line.startsWith(':')) {
              // comment / heartbeat
            } else if (line.startsWith('event: ')) {
              event = line.substring(7);
            } else if (line.startsWith('data: ')) {
              data.write(line.substring(6));
            }
          },
          onDone: () => closed = true,
          onError: (Object _) => closed = true,
        );
    await opened.future.timeout(const Duration(seconds: 30));
  }

  void _dispatch(String event, String data, Completer<void> opened) {
    if (event == 'ctl') {
      final json = jsonDecode(data) as Map<String, Object?>;
      if (json['t'] == 'sse_open') {
        stream = json['stream']! as String;
        opened.complete();
        return;
      }
      if (json['t'] == 'sse_close') {
        closeCode = json['code'] as int?;
        return;
      }
      inbox.add(decodeServerMessage(data));
    } else if (event == 'out') {
      final json = jsonDecode(data) as Map<String, Object?>;
      var bytes = base64Decode(json['d']! as String);
      var seq = json['seq']! as int;
      final expected = lastSeq;
      if (expected != null && seq < expected) {
        final skip = expected - seq;
        if (skip >= bytes.length) return;
        bytes = Uint8List.sublistView(bytes, skip);
        seq = expected;
      }
      output.write(latin1.decode(bytes));
      lastSeq = seq + bytes.length;
      frames.add(
        OutputFrame(
          session: SessionId.parse(json['s']! as String),
          seq: seq,
          data: bytes,
        ),
      );
    }
  }

  /// Posts [messages] (control objects or input maps) after earlier posts.
  Future<int> post(List<Object?> messages) {
    final done = Completer<int>();
    _sendChain = _sendChain.then((_) async {
      final req = await http.postUrl(
        base.resolve('api/sse/send?stream=$stream'),
      );
      headers.forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(messages)));
      final res = await req.close();
      await res.drain<void>();
      done.complete(res.statusCode);
    });
    return done.future;
  }

  Future<int> send(ClientMessage m) => post([jsonDecode(encodeMessage(m))]);

  Future<int> input(
    SessionId session,
    String text, {
    int? id,
    bool prompter = false,
  }) => post([
    {
      't': 'in',
      'session': '$session',
      'id': id ?? nextId++,
      'd': base64Encode(utf8.encode(text)),
      'p': prompter,
    },
  ]);

  Future<T> next<T extends ServerMessage>({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final sw = Stopwatch()..start();
    while (true) {
      final i = inbox.indexWhere((m) => m is T);
      if (i >= 0) return inbox.removeAt(i) as T;
      if (closed) throw StateError('closed while waiting for $T');
      if (sw.elapsed > timeout) throw TimeoutException('no $T');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> waitOutput(
    String needle, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final sw = Stopwatch()..start();
    while (!output.toString().contains(needle)) {
      if (sw.elapsed > timeout) {
        throw TimeoutException('no "$needle" in ${output.length} bytes');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<void> close() async {
    http.close(force: true);
    closed = true;
  }
}
