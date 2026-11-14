import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:tp_protocol/tp_protocol.dart';

import '../client_info.dart';
import '../storage.dart';
import 'ws_transport.dart';

/// Connection state shown in the top bar.
sealed class ConnState {
  const ConnState();
}

/// Not connected; [reason] explains why, [retryIn] when the next attempt is.
final class Disconnected extends ConnState {
  const Disconnected(this.reason, {this.retryIn});

  /// Short description.
  final String reason;

  /// Delay until the next attempt, if one is scheduled.
  final Duration? retryIn;
}

/// Socket opening or handshake in progress.
final class Connecting extends ConnState {
  const Connecting();
}

/// Attached to a session and exchanging data.
final class Live extends ConnState {
  const Live({required this.session, required this.name});

  /// Attached session.
  final SessionId session;

  /// Its name.
  final String name;
}

/// What the connection needs from the terminal view.
abstract interface class TerminalSink {
  /// Current size in cells.
  (int cols, int rows) get size;

  /// Writes output bytes.
  void writeOutput(Uint8List data);

  /// Writes a status line (not from the PTY), e.g. "[session ended]".
  void writeNotice(String text);

  /// Clears the screen and scrollback before a full replay.
  void clearAll();
}

/// Milestone M2 connection engine: connect, hello, attach, exchange frames,
/// resume with `last_seq` after a drop, fixed reconnect delay. The full
/// backoff state machine and SSE fallback arrive in M3 (docs/03).
final class Connection {
  /// Creates the engine for [terminal].
  Connection({
    required this.terminal,
    required String wsUrl,
    Storage storage = const Storage(),
  }) : _wsUrl = wsUrl,
       _storage = storage;

  static const String _sessionKey = 'tp.session';
  static const Duration _reconnectDelay = Duration(seconds: 2);

  /// The terminal view.
  final TerminalSink terminal;

  final String _wsUrl;
  final Storage _storage;
  final StreamController<ConnState> _states =
      StreamController<ConnState>.broadcast();
  final StreamController<int> _rtt = StreamController<int>.broadcast();

  WsClientTransport? _transport;
  ConnState _state = const Disconnected('not started');
  SessionId? _session;
  String _sessionName = '';
  int? _lastSeq;
  int _nextMsgId = 1;
  int _unackedBytes = 0;
  Timer? _ackTimer;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _wantNewSession = false;
  bool _stopped = false;

  /// State changes.
  Stream<ConnState> get states => _states.stream;

  /// Current state.
  ConnState get state => _state;

  /// Measured round-trip times in milliseconds.
  Stream<int> get rtt => _rtt.stream;

  /// Host part of the agent URL, for display.
  String get host => Uri.parse(_wsUrl).host;

  /// Starts connecting; reconnects automatically until [stop].
  void start() {
    _session = _storedSession();
    _connect();
  }

  /// Stops reconnecting and closes the socket.
  void stop() {
    _stopped = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _transport?.close();
  }

  /// Ends the current session and starts a new one.
  void newSession() {
    final session = _session;
    if (session != null) _sendControl(KillSession(session));
    _forgetSession();
    _wantNewSession = true;
    _transport?.close();
  }

  /// Sends keyboard input (already UTF-8 bytes) to the attached session.
  void sendInput(Uint8List data) {
    final session = _session;
    if (session == null || _state is! Live) return;
    _transport?.sendBinary(encodeInputFrame(session, _nextMsgId++, data));
  }

  /// Sends a terminal resize.
  void sendResize(int cols, int rows) {
    final session = _session;
    if (session == null || _state is! Live) return;
    _sendControl(Resize(session: session, cols: cols, rows: rows));
  }

  /// Sends a signal.
  void sendSignal(TerminalSignal signal) {
    final session = _session;
    if (session == null || _state is! Live) return;
    _sendControl(SignalMessage(session: session, signal: signal));
  }

  void _connect() {
    if (_stopped) return;
    _setState(const Connecting());
    final transport = WsClientTransport(_wsUrl);
    _transport = transport;
    transport.frames.listen(_onFrame, onDone: () => _onClosed(transport));
    unawaited(
      transport.opened.then(
        (_) {
          _sendControl(
            ClientHello(
              version: protocolVersion,
              client: clientIdentifier(),
              caps: const [Caps.binary, Caps.ackIn],
            ),
          );
        },
        onError: (Object _) {
          // onclose follows and schedules the retry.
        },
      ),
    );
  }

  void _onClosed(WsClientTransport transport) {
    if (_transport != transport) return;
    _transport = null;
    _pingTimer?.cancel();
    _ackTimer?.cancel();
    if (_stopped) {
      _setState(const Disconnected('stopped'));
      return;
    }
    final delay = _wantNewSession ? Duration.zero : _reconnectDelay;
    _setState(Disconnected('connection lost', retryIn: delay));
    _reconnectTimer = Timer(delay, _connect);
  }

  void _onFrame(ServerFrame frame) {
    try {
      switch (frame) {
        case TextServerFrame(:final text):
          _onControl(decodeServerMessage(text));
        case BinaryServerFrame(:final bytes):
          _onBinary(decodeBinaryFrame(bytes));
      }
    } on ProtocolException catch (e) {
      terminal.writeNotice('protocol error: ${e.message}');
    }
  }

  void _onControl(ServerMessage message) {
    switch (message) {
      case ServerHello():
        _attach();
      case Attached(:final session, :final name, :final truncated):
        _session = session;
        _sessionName = name;
        _storage.write(_sessionKey, session.toString());
        if (_lastSeq == null) terminal.clearAll();
        if (truncated != null) {
          terminal.writeNotice(
            '${truncated.to - truncated.from} bytes of scrollback were lost',
          );
        }
        _setState(Live(session: session, name: name));
        _startPing();
      case SessionExit(:final status):
        final how = status.signal != null
            ? 'signal ${status.signal}'
            : 'exit ${status.code}';
        terminal.writeNotice(
          'session ended ($how); press "New session" to start another',
        );
        _forgetSession();
      case ErrorMessage(:final code, :final msg):
        if (code == ErrorCode.sessionNotFound && _state is Connecting) {
          _forgetSession();
          _attach();
          return;
        }
        terminal.writeNotice('agent error: ${code.wire}: $msg');
        if (code == ErrorCode.versionMismatch) _stopped = true;
      case Pong(:final ts):
        _rtt.add(DateTime.now().millisecondsSinceEpoch - ts);
      case Notice(:final msg):
        terminal.writeNotice(msg);
      case AckIn():
      case SessionsMessage():
        break;
    }
  }

  void _onBinary(BinaryMessage message) {
    if (message is! OutputFrame) return;
    if (message.session != _session) return;
    final expected = _lastSeq;
    if (expected != null && message.seq < expected) {
      // Overlap after a resume: drop the bytes we already have.
      final skip = expected - message.seq;
      if (skip >= message.data.length) return;
      terminal.writeOutput(Uint8List.sublistView(message.data, skip));
    } else {
      terminal.writeOutput(message.data);
    }
    _lastSeq = message.seq + message.data.length;
    _unackedBytes += message.data.length;
    if (_unackedBytes >= Limits.ackEveryBytes) {
      _sendAck();
    } else {
      _ackTimer ??= Timer(Limits.ackInterval, _sendAck);
    }
  }

  void _attach() {
    final (cols, rows) = terminal.size;
    final session = _wantNewSession ? null : _session;
    _wantNewSession = false;
    _sendControl(
      Attach(
        session: session,
        cols: cols,
        rows: rows,
        lastSeq: session == null ? null : _lastSeq,
      ),
    );
  }

  void _sendAck() {
    _ackTimer?.cancel();
    _ackTimer = null;
    final session = _session;
    final seq = _lastSeq;
    if (session == null || seq == null) return;
    _unackedBytes = 0;
    _sendControl(Ack(session: session, seq: seq));
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(Limits.heartbeat, (_) {
      _sendControl(Ping(DateTime.now().millisecondsSinceEpoch));
    });
    _sendControl(Ping(DateTime.now().millisecondsSinceEpoch));
  }

  void _forgetSession() {
    _session = null;
    _sessionName = '';
    _lastSeq = null;
    _unackedBytes = 0;
    _storage.remove(_sessionKey);
  }

  SessionId? _storedSession() {
    final text = _storage.read(_sessionKey);
    return text == null ? null : SessionId.tryParse(text);
  }

  void _sendControl(ClientMessage message) =>
      _transport?.sendText(encodeMessage(message));

  void _setState(ConnState state) {
    _state = state;
    _states.add(state);
  }

  /// Name of the attached session, for display.
  String get sessionName => _sessionName;

  /// Encodes [text] for [sendInput].
  static Uint8List encodeInput(String text) => utf8.encode(text);
}
