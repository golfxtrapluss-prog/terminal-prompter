import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:tp_protocol/tp_protocol.dart';

import '../pty/errors.dart';
import '../session/session.dart';
import '../session/session_manager.dart';
import 'transport.dart';

/// Protocol handler for one client connection over any [Transport]
/// (docs/04). Handles `hello`, attach/detach, input with idempotency,
/// resize, signals, acks with flow control, session management and
/// ping/pong.
final class ClientConnection {
  /// Creates the handler.
  ClientConnection({
    required this.transport,
    required this.sessions,
    required this.agentVersion,
    required this.host,
  });

  static int _counter = 0;

  /// The underlying connection.
  final Transport transport;

  /// Session registry.
  final SessionManager sessions;

  /// Agent build identifier for `hello`.
  final String agentVersion;

  /// Hostname for `hello`.
  final String host;

  final Logger _log = Logger('conn');
  final Map<SessionId, _Attachment> _attachments = {};
  bool _helloDone = false;

  /// Key used for input idempotency: the client's instance id when given,
  /// otherwise unique to this connection.
  late String _instanceKey = 'conn-${++_counter}';

  /// Processes frames until the transport closes, then detaches everything.
  Future<void> run() async {
    _log.fine({'msg': 'conn_open', 'peer': transport.peer});
    try {
      await for (final frame in transport.frames) {
        await _handleFrame(frame);
      }
    } on Object catch (e, st) {
      _log.warning({'msg': 'conn_error', 'peer': transport.peer}, e, st);
      await transport.close(code: 1011, reason: 'internal error');
    } finally {
      for (final a in _attachments.values) {
        a.session.detach(a);
      }
      _attachments.clear();
      _log.fine({'msg': 'conn_close', 'peer': transport.peer});
    }
  }

  Future<void> _handleFrame(TransportFrame frame) async {
    try {
      switch (frame) {
        case TextFrame(:final text):
          await _handleControl(decodeClientMessage(text));
        case BinaryDataFrame(:final bytes):
          await _handleBinary(decodeBinaryFrame(bytes));
      }
    } on ProtocolException catch (e) {
      _sendError(ErrorCode.badMessage, e.message);
    } on SessionError catch (e) {
      _sendError(e.code, e.message);
    } on PtyError catch (e, st) {
      _log.warning({'msg': 'pty_error', 'peer': transport.peer}, e, st);
      _sendError(ErrorCode.internal, e.message);
    }
  }

  Future<void> _handleControl(ClientMessage message) async {
    if (message is ClientHello) {
      if (message.version > protocolVersion ||
          message.version < minSupportedProtocolVersion) {
        _sendError(
          ErrorCode.versionMismatch,
          'client protocol v${message.version}, agent speaks v$protocolVersion',
        );
        await transport.close(code: 1002, reason: 'version mismatch');
        return;
      }
      _helloDone = true;
      final instance = message.instance;
      if (instance != null && instance.isNotEmpty) _instanceKey = instance;
      _send(
        ServerHello(
          version: protocolVersion,
          agent: agentVersion,
          host: host,
          caps: const [Caps.binary, Caps.ackIn],
          sessions: sessions.list(),
        ),
      );
      return;
    }
    if (!_helloDone) {
      _sendError(ErrorCode.badMessage, 'hello must be the first message');
      return;
    }
    switch (message) {
      case ClientHello():
        break; // handled above
      case Attach():
        await _attach(message);
      case Detach(:final session):
        _attached(session); // session_not_found when not attached
        _detach(session);
      case Resize(:final session, :final cols, :final rows):
        _attached(session).session.resize(cols, rows);
      case SignalMessage(:final session, :final signal):
        await _attached(session).session.signal(signal);
      case Ack(:final session, :final seq):
        await _attached(session).onAck(seq);
      case KillSession(:final session):
        _detach(session);
        await sessions.kill(session);
        _send(SessionsMessage(sessions.list()));
      case Rename(:final session, :final name):
        sessions.require(session).name = name;
        _send(SessionsMessage(sessions.list()));
      case ListSessions():
        _send(SessionsMessage(sessions.list()));
      case Ping(:final ts):
        _send(Pong(ts));
    }
  }

  Future<void> _handleBinary(BinaryMessage message) async {
    switch (message) {
      case InputFrame(:final session, :final clientMsgId, :final data):
        if (!_helloDone) {
          _sendError(ErrorCode.badMessage, 'hello must be the first message');
          return;
        }
        final attachment = _attached(session);
        // A frame resent after a reconnect is acknowledged but not written
        // again, so a command never runs twice (docs/04 "Input-idempotens").
        if (!attachment.session.deduper.isDuplicate(
          _instanceKey,
          clientMsgId,
        )) {
          await attachment.session.write(data);
        }
        _send(AckIn(session: session, id: clientMsgId));
      case OutputFrame():
        throw const ProtocolException('clients cannot send output frames');
    }
  }

  Future<void> _attach(Attach message) async {
    final Session session;
    if (message.session == null) {
      session = await sessions.create(
        name: message.name ?? '',
        cols: message.cols,
        rows: message.rows,
      );
    } else {
      session = sessions.require(message.session!);
      if (session.exited == null &&
          (session.cols != message.cols || session.rows != message.rows)) {
        session.resize(message.cols, message.rows);
      }
    }
    _detach(session.id);
    final attachment = _Attachment(this, session);
    _attachments[session.id] = attachment;
    final replay = session.attach(attachment, fromSeq: message.lastSeq);
    _send(
      Attached(
        session: session.id,
        name: session.name,
        seq: session.buffer.seq,
        cols: session.cols,
        rows: session.rows,
        truncated: replay.truncated,
      ),
    );
    attachment.ackedSeq = replay.startSeq;
    attachment.sentSeq = replay.startSeq;
    attachment.deliver(replay.startSeq, replay.data);
    final exited = session.exited;
    if (exited != null) _send(SessionExit(session: session.id, status: exited));
  }

  void _detach(SessionId id) {
    final attachment = _attachments.remove(id);
    attachment?.session.detach(attachment);
  }

  _Attachment _attached(SessionId id) =>
      _attachments[id] ?? (throw SessionNotFoundError(id));

  void _send(ServerMessage message) =>
      transport.sendText(encodeMessage(message));

  void _sendError(ErrorCode code, String msg, [SessionId? session]) =>
      _send(ErrorMessage(code: code, msg: msg, session: session));

  /// Sends [data] as output frames of at most `Limits.maxOutputFrameBytes`.
  void _sendOutput(SessionId id, int startSeq, Uint8List data) {
    for (var offset = 0; offset < data.length;) {
      final end = math.min(offset + Limits.maxOutputFrameBytes, data.length);
      transport.sendBinary(
        encodeOutputFrame(
          id,
          startSeq + offset,
          Uint8List.sublistView(data, offset, end),
        ),
      );
      offset = end;
    }
  }

  Future<void> _dropSlowConsumer(Session session) async {
    _log.info({
      'msg': 'slow_consumer',
      'peer': transport.peer,
      'sid': '${session.id}',
    });
    await transport.close(code: 1008, reason: 'slow consumer');
  }
}

/// One session attached to one connection, with per-client flow control
/// (docs/04 "Flytkontroll"): live output is pushed until
/// `Limits.maxUnackedOutputBytes` is unacknowledged, then the attachment
/// pauses and catches up from the ring buffer when acks arrive. A paused
/// client whose resume point has been overwritten is disconnected and
/// resumes from `last_seq`.
final class _Attachment implements SessionSubscriber {
  _Attachment(this.connection, this.session);

  final ClientConnection connection;
  final Session session;

  /// Next sequence number the client expects from us.
  int sentSeq = 0;

  /// Highest sequence number the client has acknowledged.
  int ackedSeq = 0;

  /// True while live output is withheld pending acks.
  bool paused = false;

  int get unacked => sentSeq - ackedSeq;

  /// Sends [data] starting at [seq] unless it is already past [sentSeq]
  /// (overlap after a catch-up) or the client is paused.
  void deliver(int seq, Uint8List data) {
    if (paused) return;
    if (seq + data.length <= sentSeq) return;
    if (seq < sentSeq) {
      data = Uint8List.sublistView(data, sentSeq - seq);
      seq = sentSeq;
    }
    connection._sendOutput(session.id, seq, data);
    sentSeq = seq + data.length;
    if (unacked >= Limits.maxUnackedOutputBytes) paused = true;
  }

  Future<void> onAck(int seq) async {
    if (seq > ackedSeq) ackedSeq = math.min(seq, sentSeq);
    if (!paused || unacked >= Limits.maxUnackedOutputBytes ~/ 2) return;
    // Catch up from the ring buffer with everything produced while paused.
    final read = session.buffer.readFrom(sentSeq);
    if (read.truncated != null) {
      await connection._dropSlowConsumer(session);
      return;
    }
    paused = false;
    deliver(read.startSeq, read.data);
  }

  @override
  void onOutput(Session session, int seq, Uint8List data) {
    deliver(seq, data);
    // A client that never acks must not pin unbounded data; once the ring
    // buffer no longer covers its position it will be dropped on next ack.
    // Until then its memory cost is bounded by the ring buffer itself.
    if (paused &&
        session.buffer.seq - ackedSeq >= Limits.slowConsumerDisconnectBytes) {
      unawaited(connection._dropSlowConsumer(session));
    }
  }

  @override
  void onExit(Session session, ExitStatus status) =>
      connection._send(SessionExit(session: session.id, status: status));
}
