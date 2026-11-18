import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:tp_protocol/tp_protocol.dart';

import 'transport.dart';

/// Connection state (docs/03 "Tilkoblingsmotor").
///
/// ```text
/// disconnected -> connecting -> attaching -> live
///       ^             |            |          |
///       +--- backoff <+------------+----------+
/// ```
/// `authCheck` is added in M5 together with login.
sealed class ConnState {
  const ConnState();
}

/// Not connected; [reason] explains why, [retryIn] when the next attempt is.
final class Disconnected extends ConnState {
  const Disconnected(this.reason, {this.retryIn, this.attempt = 0});

  /// Short description.
  final String reason;

  /// Delay until the next attempt, if one is scheduled.
  final Duration? retryIn;

  /// Number of consecutive failed attempts.
  final int attempt;
}

/// Socket opening or `hello` in flight.
final class Connecting extends ConnState {
  const Connecting();
}

/// `attach` sent, waiting for `attached`.
final class Attaching extends ConnState {
  const Attaching();
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

  /// Writes output bytes. [replay] is true for scrollback re-sent after an
  /// attach: the terminal must not answer queries contained in it (DA,
  /// colour or mode queries from vim/htop), or the answers would reach the
  /// shell as typed input.
  void writeOutput(Uint8List data, {bool replay = false});

  /// Writes a status line (not from the PTY), e.g. "[session ended]".
  void writeNotice(String text);

  /// Clears the screen and scrollback before a full replay.
  void clearAll();
}

/// Connection engine: connect, hello, attach, exchange frames, resume with
/// `last_seq`, reconnect with jittered backoff, heartbeat watchdog, and
/// resend of unacknowledged input (idempotent via `client_msg_id` and the
/// per-instance id sent in `hello`). Platform-neutral: the browser supplies
/// a [TransportFactory], a [KeyValueStore] and calls [notifyOnline] /
/// [notifyVisible] from window events.
final class Connection {
  /// Creates the engine for [terminal].
  Connection({
    required this.terminal,
    required String wsUrl,
    required TransportFactory transportFactory,
    required String clientId,
    KeyValueStore? store,
    Backoff? backoff,
    Duration heartbeat = Limits.heartbeat,
    Duration deadAfter = Limits.deadAfter,
    Random? random,
  }) : _wsUrl = wsUrl,
       _factory = transportFactory,
       _clientId = clientId,
       _store = store ?? MemoryStore(),
       _backoff = backoff ?? Backoff(),
       _heartbeat = heartbeat,
       _deadAfter = deadAfter,
       _instance = _randomId(random ?? Random.secure());

  static const String _sessionKey = 'tp.session';

  /// The terminal view.
  final TerminalSink terminal;

  final String _wsUrl;
  final TransportFactory _factory;
  final String _clientId;
  final KeyValueStore _store;
  final Backoff _backoff;
  final Duration _heartbeat;
  final Duration _deadAfter;
  final String _instance;
  final StreamController<ConnState> _states =
      StreamController<ConnState>.broadcast();
  final StreamController<int> _rtt = StreamController<int>.broadcast();
  final StreamController<int> _acks = StreamController<int>.broadcast();
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();

  /// Input sent but not yet confirmed with `ack_in`, in send order.
  final Map<int, Uint8List> _unackedInput = {};

  ClientTransport? _transport;
  ConnState _state = const Disconnected('not started');
  SessionId? _session;
  String _sessionName = '';
  int? _lastSeq;

  /// Output before this sequence number is replay from the ring buffer.
  int _replayEnd = 0;
  int _nextMsgId = 1;
  int _unackedOutputBytes = 0;
  int _attempt = 0;
  DateTime _lastTraffic = DateTime.now();
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

  /// `client_msg_id`s confirmed by the agent (`ack_in`).
  Stream<int> get acks => _acks.stream;

  /// Output bytes as written to the terminal (for mode tracking).
  Stream<Uint8List> get output => _output.stream;

  /// True while attached to a session.
  bool get isLive => _state is Live;

  /// Host part of the agent URL, for display.
  String get host => Uri.parse(_wsUrl).host;

  /// Name of the attached session, for display.
  String get sessionName => _sessionName;

  /// Random id of this client instance, sent in `hello`.
  String get instanceId => _instance;

  /// Highest output sequence number received, for tests and diagnostics.
  int? get lastSeq => _lastSeq;

  /// Number of input frames awaiting `ack_in`.
  int get pendingInput => _unackedInput.length;

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
    _ackTimer?.cancel();
    _transport?.close();
  }

  /// Browser came back online: retry immediately.
  void notifyOnline() => _retryNow();

  /// Tab became visible: retry immediately if disconnected.
  void notifyVisible() => _retryNow();

  /// Ends the current session and starts a new one.
  void newSession() {
    final session = _session;
    if (session != null) _sendControl(KillSession(session));
    _forgetSession();
    _wantNewSession = true;
    _transport?.close();
  }

  /// Sends keyboard input (UTF-8 bytes) to the attached session. Input is
  /// kept until acknowledged and resent after a reconnect. Returns the
  /// `client_msg_id`, or null when there is no session to send to.
  int? sendInput(Uint8List data) {
    final session = _session;
    if (session == null) return null;
    final id = _nextMsgId++;
    _unackedInput[id] = data;
    if (_state is Live) {
      _transport?.sendBinary(encodeInputFrame(session, id, data));
    }
    return id;
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
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _setState(const Connecting());
    final transport = _factory(_wsUrl);
    _transport = transport;
    _lastTraffic = DateTime.now();
    transport.frames.listen(
      _onFrame,
      onDone: () => _onClosed(transport),
      onError: (Object _) {},
    );
    unawaited(
      transport.opened.then(
        (_) {
          if (_transport != transport) return;
          _sendControl(
            ClientHello(
              version: protocolVersion,
              client: _clientId,
              caps: const [Caps.binary, Caps.ackIn],
              instance: _instance,
            ),
          );
          _startHeartbeat();
        },
        onError: (Object _) {
          // The frames stream ends next and schedules the retry.
        },
      ),
    );
  }

  void _onClosed(ClientTransport transport) {
    if (_transport != transport) return;
    _transport = null;
    _pingTimer?.cancel();
    _ackTimer?.cancel();
    _ackTimer = null;
    if (_stopped) {
      _setState(const Disconnected('stopped'));
      return;
    }
    final wasLive = _state is Live;
    if (wasLive) _attempt = 0;
    final delay = _wantNewSession ? Duration.zero : _backoff.delay(_attempt);
    _setState(
      Disconnected(
        wasLive ? 'connection lost' : 'cannot reach agent',
        retryIn: delay,
        attempt: _attempt,
      ),
    );
    _attempt++;
    _reconnectTimer = Timer(delay, _connect);
  }

  void _retryNow() {
    if (_stopped || _transport != null || _state is! Disconnected) return;
    _connect();
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_heartbeat, (_) {
      if (DateTime.now().difference(_lastTraffic) > _deadAfter) {
        // Silent socket: treat as dead so the backoff path reconnects.
        _transport?.close();
        return;
      }
      _sendControl(Ping(DateTime.now().millisecondsSinceEpoch));
    });
  }

  void _onFrame(ServerFrame frame) {
    _lastTraffic = DateTime.now();
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
      case Attached(:final session, :final name, :final truncated, :final seq):
        final resumed = session == _session && _lastSeq != null;
        _replayEnd = seq;
        _session = session;
        _sessionName = name;
        _store.write(_sessionKey, session.toString());
        if (!resumed) {
          _lastSeq = null;
          _unackedOutputBytes = 0;
          terminal.clearAll();
        }
        if (truncated != null) {
          terminal.writeNotice(
            '${truncated.to - truncated.from} bytes of scrollback were lost',
          );
        }
        _attempt = 0;
        _setState(Live(session: session, name: name));
        _resendUnackedInput();
        _sendControl(Ping(DateTime.now().millisecondsSinceEpoch)); // first RTT
      case AckIn(:final id):
        _unackedInput.remove(id);
        _acks.add(id);
      case SessionExit(:final status):
        final how = status.signal != null
            ? 'signal ${status.signal}'
            : 'exit ${status.code}';
        terminal.writeNotice(
          'session ended ($how); press "New session" to start another',
        );
        _forgetSession();
      case ErrorMessage(:final code, :final msg):
        if (code == ErrorCode.sessionNotFound && _state is Attaching) {
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
      case SessionsMessage():
        break;
    }
  }

  void _onBinary(BinaryMessage message) {
    if (message is! OutputFrame || message.session != _session) return;
    final expected = _lastSeq;
    var data = message.data;
    if (expected != null && message.seq < expected) {
      // Overlap after a resume: drop the bytes we already have.
      final skip = expected - message.seq;
      if (skip >= data.length) return;
      data = Uint8List.sublistView(data, skip);
    }
    terminal.writeOutput(data, replay: message.seq < _replayEnd);
    _output.add(data);
    _lastSeq = message.seq + message.data.length;
    _unackedOutputBytes += data.length;
    if (_unackedOutputBytes >= Limits.ackEveryBytes) {
      _sendAck();
    } else {
      _ackTimer ??= Timer(Limits.ackInterval, _sendAck);
    }
  }

  void _attach() {
    final (cols, rows) = terminal.size;
    final session = _wantNewSession ? null : _session;
    _wantNewSession = false;
    _setState(const Attaching());
    _sendControl(
      Attach(
        session: session,
        cols: cols,
        rows: rows,
        lastSeq: session == null ? null : _lastSeq,
      ),
    );
  }

  void _resendUnackedInput() {
    final session = _session;
    final transport = _transport;
    if (session == null || transport == null) return;
    for (final entry in _unackedInput.entries) {
      transport.sendBinary(encodeInputFrame(session, entry.key, entry.value));
    }
  }

  void _sendAck() {
    _ackTimer?.cancel();
    _ackTimer = null;
    final session = _session;
    final seq = _lastSeq;
    if (session == null || seq == null) return;
    _unackedOutputBytes = 0;
    _sendControl(Ack(session: session, seq: seq));
  }

  void _forgetSession() {
    _session = null;
    _sessionName = '';
    _lastSeq = null;
    _unackedOutputBytes = 0;
    _unackedInput.clear();
    _store.remove(_sessionKey);
  }

  SessionId? _storedSession() {
    final text = _store.read(_sessionKey);
    return text == null ? null : SessionId.tryParse(text);
  }

  void _sendControl(ClientMessage message) =>
      _transport?.sendText(encodeMessage(message));

  void _setState(ConnState state) {
    _state = state;
    _states.add(state);
  }

  /// Encodes [text] for [sendInput].
  static Uint8List encodeInput(String text) => utf8.encode(text);

  static String _randomId(Random random) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return String.fromCharCodes(
      List.generate(
        16,
        (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ),
    );
  }
}
