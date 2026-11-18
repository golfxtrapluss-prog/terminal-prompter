import 'dart:convert';
import 'dart:typed_data';

import 'limits.dart';
import 'messages.dart';
import 'session_id.dart';

/// Thrown when a message cannot be decoded or fails validation. The agent
/// answers with `error {code: bad_message}`.
final class ProtocolException implements Exception {
  /// Creates the exception.
  const ProtocolException(this.message);

  /// What was wrong.
  final String message;

  @override
  String toString() => 'ProtocolException: $message';
}

/// Encodes any control message as a JSON text frame.
String encodeMessage(ProtocolMessage message) =>
    jsonEncode(messageToJson(message));

/// Converts a control message to its JSON map (`t` plus fields).
Map<String, Object?> messageToJson(ProtocolMessage message) {
  final map = <String, Object?>{'t': message.type};
  switch (message) {
    case ClientHello(
      :final version,
      :final client,
      :final caps,
      :final instance,
    ):
      map['v'] = version;
      map['client'] = client;
      map['caps'] = caps;
      if (instance != null) map['instance'] = instance;
    case Attach(
      :final session,
      :final name,
      :final cols,
      :final rows,
      :final lastSeq,
    ):
      map['session'] = session?.toString();
      if (name != null) map['name'] = name;
      map['cols'] = cols;
      map['rows'] = rows;
      if (lastSeq != null) map['last_seq'] = lastSeq;
    case Detach(:final session):
      map['session'] = session.toString();
    case Resize(:final session, :final cols, :final rows):
      map['session'] = session.toString();
      map['cols'] = cols;
      map['rows'] = rows;
    case SignalMessage(:final session, :final signal):
      map['session'] = session.toString();
      map['sig'] = signal.wire;
    case Ack(:final session, :final seq):
      map['session'] = session.toString();
      map['seq'] = seq;
    case KillSession(:final session):
      map['session'] = session.toString();
    case Rename(:final session, :final name):
      map['session'] = session.toString();
      map['name'] = name;
    case ListSessions():
      break;
    case Ping(:final ts):
      map['ts'] = ts;
    case ServerHello(
      :final version,
      :final agent,
      :final host,
      :final caps,
      :final sessions,
    ):
      map['v'] = version;
      map['agent'] = agent;
      map['host'] = host;
      map['caps'] = caps;
      map['sessions'] = [for (final s in sessions) _sessionInfoToJson(s)];
    case Attached(
      :final session,
      :final name,
      :final seq,
      :final cols,
      :final rows,
      :final truncated,
    ):
      map['session'] = session.toString();
      map['name'] = name;
      map['seq'] = seq;
      map['cols'] = cols;
      map['rows'] = rows;
      if (truncated != null) {
        map['truncated'] = {'from': truncated.from, 'to': truncated.to};
      }
    case SessionsMessage(:final sessions):
      map['sessions'] = [for (final s in sessions) _sessionInfoToJson(s)];
    case SessionExit(:final session, :final status):
      map['session'] = session.toString();
      map['code'] = status.code;
      if (status.signal != null) map['signal'] = status.signal;
    case Pong(:final ts):
      map['ts'] = ts;
    case AckIn(:final session, :final id):
      map['session'] = session.toString();
      map['id'] = id;
    case ErrorMessage(:final code, :final msg, :final session):
      map['code'] = code.wire;
      map['msg'] = msg;
      if (session != null) map['session'] = session.toString();
    case Notice(:final level, :final msg):
      map['level'] = level;
      map['msg'] = msg;
    default:
      throw ArgumentError.value(message, 'message', 'unknown message class');
  }
  return map;
}

/// Decodes a JSON text frame sent by a client.
ClientMessage decodeClientMessage(String text) {
  final m = _Fields(_parse(text));
  switch (m.type) {
    case 'hello':
      return ClientHello(
        version: m.int_('v', min: 0),
        client: m.string('client', max: Limits.maxTextLength),
        caps: m.caps(),
        instance: m.stringOrNull('instance', max: Limits.maxInstanceIdLength),
      );
    case 'attach':
      return Attach(
        session: m.sessionIdOrNull('session'),
        name: m.stringOrNull('name', max: Limits.maxSessionNameLength),
        cols: m.dimension('cols'),
        rows: m.dimension('rows'),
        lastSeq: m.intOrNull('last_seq', min: 0),
      );
    case 'detach':
      return Detach(m.sessionId('session'));
    case 'resize':
      return Resize(
        session: m.sessionId('session'),
        cols: m.dimension('cols'),
        rows: m.dimension('rows'),
      );
    case 'signal':
      final wire = m.string('sig', max: 8);
      final signal = TerminalSignal.fromWire(wire);
      if (signal == null) throw ProtocolException('unknown signal "$wire"');
      return SignalMessage(session: m.sessionId('session'), signal: signal);
    case 'ack':
      return Ack(session: m.sessionId('session'), seq: m.int_('seq', min: 0));
    case 'kill':
      return KillSession(m.sessionId('session'));
    case 'rename':
      return Rename(
        session: m.sessionId('session'),
        name: m.string('name', max: Limits.maxSessionNameLength),
      );
    case 'list':
      return const ListSessions();
    case 'ping':
      return Ping(m.int_('ts', min: 0));
    default:
      throw ProtocolException('unknown client message type "${m.type}"');
  }
}

/// Decodes a JSON text frame sent by the server.
ServerMessage decodeServerMessage(String text) {
  final m = _Fields(_parse(text));
  switch (m.type) {
    case 'hello':
      return ServerHello(
        version: m.int_('v', min: 0),
        agent: m.string('agent', max: Limits.maxTextLength),
        host: m.string('host', max: Limits.maxTextLength),
        caps: m.caps(),
        sessions: m.sessions(),
      );
    case 'attached':
      final truncated = m.map.containsKey('truncated')
          ? _Fields(m.mapField('truncated'))
          : null;
      return Attached(
        session: m.sessionId('session'),
        name: m.string('name', max: Limits.maxSessionNameLength),
        seq: m.int_('seq', min: 0),
        cols: m.dimension('cols'),
        rows: m.dimension('rows'),
        truncated: truncated == null
            ? null
            : (
                from: truncated.int_('from', min: 0),
                to: truncated.int_('to', min: 0),
              ),
      );
    case 'sessions':
      return SessionsMessage(m.sessions());
    case 'exit':
      return SessionExit(
        session: m.sessionId('session'),
        status: ExitStatus(
          code: m.intOrNull('code', min: 0),
          signal: m.intOrNull('signal', min: 1),
        ),
      );
    case 'pong':
      return Pong(m.int_('ts', min: 0));
    case 'ack_in':
      return AckIn(session: m.sessionId('session'), id: m.int_('id', min: 0));
    case 'error':
      final wire = m.string('code', max: 32);
      final code = ErrorCode.fromWire(wire);
      if (code == null) throw ProtocolException('unknown error code "$wire"');
      return ErrorMessage(
        code: code,
        msg: m.string('msg', max: Limits.maxTextLength),
        session: m.sessionIdOrNull('session'),
      );
    case 'notice':
      return Notice(
        level: m.string('level', max: 16),
        msg: m.string('msg', max: Limits.maxTextLength),
      );
    default:
      throw ProtocolException('unknown server message type "${m.type}"');
  }
}

/// A decoded binary frame.
sealed class BinaryMessage {
  const BinaryMessage();
}

/// Terminal output, server to client.
final class OutputFrame extends BinaryMessage {
  /// Creates the frame.
  const OutputFrame({
    required this.session,
    required this.seq,
    required this.data,
  });

  /// Session id.
  final SessionId session;

  /// Sequence number of the first byte in [data].
  final int seq;

  /// Raw bytes from the PTY.
  final Uint8List data;
}

/// Terminal input, client to server.
final class InputFrame extends BinaryMessage {
  /// Creates the frame.
  const InputFrame({
    required this.session,
    required this.clientMsgId,
    required this.data,
    this.fromPrompter = false,
  });

  /// True for frame type `0x04` (a command line from the Prompter field).
  final bool fromPrompter;

  /// Session id.
  final SessionId session;

  /// Per-connection increasing id that makes resends idempotent.
  final int clientMsgId;

  /// Raw bytes for the PTY.
  final Uint8List data;
}

/// Encodes an output frame.
Uint8List encodeOutputFrame(SessionId session, int seq, List<int> data) =>
    _encodeFrame(BinaryFrame.typeOutput, session, seq, data);

/// Encodes an input frame; [fromPrompter] selects frame type `0x04`.
Uint8List encodeInputFrame(
  SessionId session,
  int clientMsgId,
  List<int> data, {
  bool fromPrompter = false,
}) => _encodeFrame(
  fromPrompter ? BinaryFrame.typePrompterInput : BinaryFrame.typeInput,
  session,
  clientMsgId,
  data,
);

/// Decodes a binary frame of either direction.
BinaryMessage decodeBinaryFrame(Uint8List bytes) {
  if (bytes.length < BinaryFrame.headerLength) {
    throw const ProtocolException('binary frame shorter than header');
  }
  final session = SessionId(
    Uint8List.sublistView(bytes, 1, 1 + Limits.sessionIdBytes),
  );
  final number = _readUint64(bytes, 1 + Limits.sessionIdBytes);
  final data = Uint8List.sublistView(bytes, BinaryFrame.headerLength);
  switch (bytes[0]) {
    case BinaryFrame.typeOutput:
      return OutputFrame(session: session, seq: number, data: data);
    case BinaryFrame.typeInput || BinaryFrame.typePrompterInput:
      if (data.length > Limits.maxInputFrameBytes) {
        throw const ProtocolException('input frame too large');
      }
      return InputFrame(
        session: session,
        clientMsgId: number,
        data: data,
        fromPrompter: bytes[0] == BinaryFrame.typePrompterInput,
      );
    case BinaryFrame.typeExecOut:
      throw const ProtocolException('exec_out frames are reserved for v2');
    default:
      throw ProtocolException('unknown binary frame type ${bytes[0]}');
  }
}

Uint8List _encodeFrame(
  int type,
  SessionId session,
  int number,
  List<int> data,
) {
  if (number < 0) throw ArgumentError.value(number, 'number', 'must be >= 0');
  final out = Uint8List(BinaryFrame.headerLength + data.length);
  out[0] = type;
  out.setRange(1, 1 + Limits.sessionIdBytes, session.bytes);
  _writeUint64(out, 1 + Limits.sessionIdBytes, number);
  out.setRange(BinaryFrame.headerLength, out.length, data);
  return out;
}

const int _two32 = 0x100000000;

// 64-bit integers are split into two 32-bit halves so the code also runs
// under dart2js, where ByteData.setUint64 is unsupported.
void _writeUint64(Uint8List out, int offset, int value) {
  final view = ByteData.sublistView(out, offset, offset + 8);
  final hi = value ~/ _two32;
  view.setUint32(0, hi);
  view.setUint32(4, value - hi * _two32);
}

int _readUint64(Uint8List bytes, int offset) {
  final view = ByteData.sublistView(bytes, offset, offset + 8);
  return view.getUint32(0) * _two32 + view.getUint32(4);
}

Map<String, Object?> _parse(String text) {
  if (text.length > Limits.maxControlMessageBytes) {
    throw const ProtocolException('control message too large');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    throw ProtocolException('invalid JSON: ${e.message}');
  }
  if (decoded is! Map<String, Object?>) {
    throw const ProtocolException('control message must be a JSON object');
  }
  return decoded;
}

Map<String, Object?> _sessionInfoToJson(SessionInfo s) => {
  'id': s.id.toString(),
  'name': s.name,
  'created': s.created.toUtc().toIso8601String(),
  'last_seen': s.lastSeen.toUtc().toIso8601String(),
  'clients': s.clients,
  if (s.exited != null)
    'exited': {
      'code': s.exited!.code,
      if (s.exited!.signal != null) 'signal': s.exited!.signal,
    },
};

/// Typed, validating accessors over a decoded JSON object.
final class _Fields {
  _Fields(this.map);

  final Map<String, Object?> map;

  String get type {
    final t = map['t'];
    if (t is! String) throw const ProtocolException('missing "t"');
    return t;
  }

  int int_(String key, {required int min, int? max}) {
    final v = intOrNull(key, min: min, max: max);
    if (v == null) throw ProtocolException('missing "$key"');
    return v;
  }

  int? intOrNull(String key, {required int min, int? max}) {
    final v = map[key];
    if (v == null) return null;
    if (v is! int) throw ProtocolException('"$key" must be an integer');
    if (v < min || (max != null && v > max)) {
      throw ProtocolException('"$key" out of range');
    }
    return v;
  }

  int dimension(String key) => int_(key, min: 1, max: Limits.maxDimension);

  String string(String key, {required int max}) {
    final v = stringOrNull(key, max: max);
    if (v == null) throw ProtocolException('missing "$key"');
    return v;
  }

  String? stringOrNull(String key, {required int max}) {
    final v = map[key];
    if (v == null) return null;
    if (v is! String) throw ProtocolException('"$key" must be a string');
    if (v.length > max) throw ProtocolException('"$key" too long');
    return v;
  }

  SessionId sessionId(String key) {
    final v = sessionIdOrNull(key);
    if (v == null) throw ProtocolException('missing "$key"');
    return v;
  }

  SessionId? sessionIdOrNull(String key) {
    final text = stringOrNull(key, max: SessionId.textLength);
    if (text == null) return null;
    final id = SessionId.tryParse(text);
    if (id == null) throw ProtocolException('"$key" is not a session id');
    return id;
  }

  Map<String, Object?> mapField(String key) {
    final v = map[key];
    if (v is! Map<String, Object?>) {
      throw ProtocolException('"$key" must be an object');
    }
    return v;
  }

  List<String> caps() {
    final v = map['caps'];
    if (v == null) return const [];
    if (v is! List) throw const ProtocolException('"caps" must be a list');
    if (v.length > Limits.maxCaps) {
      throw const ProtocolException('too many caps');
    }
    return [
      for (final c in v)
        if (c is String && c.length <= 32)
          c
        else
          throw const ProtocolException('invalid capability'),
    ];
  }

  List<SessionInfo> sessions() {
    final v = map['sessions'];
    if (v == null) return const [];
    if (v is! List) throw const ProtocolException('"sessions" must be a list');
    return [
      for (final item in v)
        if (item is Map<String, Object?>)
          _sessionInfo(_Fields(item))
        else
          throw const ProtocolException('invalid session entry'),
    ];
  }

  static SessionInfo _sessionInfo(_Fields f) {
    final exited = f.map.containsKey('exited')
        ? _Fields(f.mapField('exited'))
        : null;
    return SessionInfo(
      id: f.sessionId('id'),
      name: f.string('name', max: Limits.maxSessionNameLength),
      created: f.dateTime('created'),
      lastSeen: f.dateTime('last_seen'),
      clients: f.int_('clients', min: 0),
      exited: exited == null
          ? null
          : ExitStatus(
              code: exited.intOrNull('code', min: 0),
              signal: exited.intOrNull('signal', min: 1),
            ),
    );
  }

  DateTime dateTime(String key) {
    final text = string(key, max: 64);
    final value = DateTime.tryParse(text);
    if (value == null) throw ProtocolException('"$key" is not a timestamp');
    return value;
  }
}
