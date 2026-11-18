import 'dart:async';
import 'dart:convert';
import 'dart:io' show ProcessSignal;
import 'dart:typed_data';

import 'package:tp_protocol/tp_protocol.dart';

import '../pty/pty_process.dart';
import 'ring_buffer.dart';

/// Receives a session's output and lifecycle events.
abstract interface class SessionSubscriber {
  /// Output bytes starting at sequence number [seq].
  void onOutput(Session session, int seq, Uint8List data);

  /// The session's process ended.
  void onExit(Session session, ExitStatus status);
}

/// One shell in one PTY, living independently of client connections
/// (docs/02 "Sesjonsmodell", ADR-006).
///
/// Output is numbered per byte in a [RingBuffer]; subscribers receive it
/// coalesced into frames of at most `Limits.maxOutputFrameBytes`, flushed
/// after [coalesce] or when the pending data grows past that size.
final class Session {
  /// Wraps a running [pty].
  Session({
    required this.id,
    required this.name,
    required this.pty,
    required int scrollbackBytes,
    required this.coalesce,
    DateTime Function()? clock,
  }) : buffer = RingBuffer(scrollbackBytes),
       _clock = clock ?? DateTime.now {
    created = _clock();
    lastSeen = created;
    _outputSubscription = pty.output.listen(_onChunk, onDone: _onOutputDone);
    unawaited(pty.exited.then(_onExit));
  }

  /// Session id.
  final SessionId id;

  /// Human-readable name.
  String name;

  /// The process behind the session.
  final PtyProcess pty;

  /// Retained output.
  final RingBuffer buffer;

  /// Input idempotency per client instance (docs/04).
  final InputDeduper deduper = InputDeduper();

  /// How long output is batched before being sent to subscribers.
  final Duration coalesce;

  final DateTime Function() _clock;
  final Set<SessionSubscriber> _subscribers = {};
  late final StreamSubscription<Uint8List> _outputSubscription;
  final Completer<void> _outputDone = Completer<void>();

  BytesBuilder? _pending;
  int _pendingStart = 0;
  Timer? _flushTimer;
  ExitStatus? _exited;
  DateTime? _exitedAt;

  /// When the session was created.
  late final DateTime created;

  /// Last attach or input.
  late DateTime lastSeen;

  /// Set once the process has ended.
  ExitStatus? get exited => _exited;

  /// When the process ended.
  DateTime? get exitedAt => _exitedAt;

  /// Number of attached subscribers.
  int get clients => _subscribers.length;

  /// Current terminal width.
  int get cols => pty.cols;

  /// Current terminal height.
  int get rows => pty.rows;

  /// Completes when the process has exited and all output has been read.
  Future<void> get done => Future.wait([pty.exited, _outputDone.future]);

  /// Summary for session lists.
  SessionInfo get info => SessionInfo(
    id: id,
    name: name,
    created: created,
    lastSeen: lastSeen,
    clients: clients,
    exited: _exited,
  );

  /// Subscribes [subscriber] and returns the output to replay first: from
  /// [fromSeq] (bytes the client already has) or the whole scrollback.
  /// Pending output is flushed first so replay and live frames never overlap.
  RingRead attach(SessionSubscriber subscriber, {int? fromSeq}) {
    _flush();
    lastSeen = _clock();
    _subscribers.add(subscriber);
    return buffer.readFrom(fromSeq ?? buffer.oldestSeq);
  }

  /// Stops delivering output to [subscriber].
  void detach(SessionSubscriber subscriber) {
    _subscribers.remove(subscriber);
  }

  /// Writes terminal input.
  Future<void> write(List<int> data) {
    lastSeen = _clock();
    return pty.write(data);
  }

  /// Changes the terminal size.
  void resize(int cols, int rows) => pty.resize(cols, rows);

  /// Delivers [signal] as described in docs/04.
  Future<void> signal(TerminalSignal signal) async {
    switch (signal) {
      case TerminalSignal.interrupt:
        await write(const [0x03]);
      case TerminalSignal.suspend:
        await write(const [0x1a]);
      case TerminalSignal.eof:
        await write(const [0x04]);
      case TerminalSignal.terminate:
        pty.kill();
      case TerminalSignal.kill:
        pty.kill(ProcessSignal.sigkill);
    }
  }

  /// Ends the process tree and releases the PTY.
  Future<void> terminate({Duration grace = const Duration(seconds: 2)}) async {
    await pty.terminate(grace: grace);
    await close();
  }

  /// Releases the PTY without killing anything that is still running.
  Future<void> close() async {
    _flush();
    await pty.close();
    await _outputSubscription.cancel();
    if (!_outputDone.isCompleted) _outputDone.complete();
  }

  /// Tail of recent output, used only to recognise a password prompt.
  String _tail = '';

  static final RegExp _passwordPrompt = RegExp(
    r'(password|passord|passphrase|passordfrase|pin)[^\n:]{0,40}:\s*$',
    caseSensitive: false,
  );
  static final RegExp _ansi = RegExp(
    r'\x1b(\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)|[@-Z\\-_])',
  );

  /// True when the last output line looks like a password prompt
  /// (`[sudo] password for tp:`, `Password:`), so the next Prompter line
  /// is masked in the audit log.
  bool get awaitingPassword {
    final clean = _tail.replaceAll(_ansi, '');
    final lastLine = clean.split(RegExp(r'[\r\n]')).last;
    return _passwordPrompt.hasMatch(lastLine);
  }

  void _onChunk(Uint8List chunk) {
    final text = latin1.decode(chunk);
    _tail = (_tail + text).length > 256
        ? (_tail + text).substring((_tail + text).length - 256)
        : _tail + text;
    final pending = _pending ??= BytesBuilder(copy: false);
    if (pending.isEmpty) _pendingStart = buffer.seq;
    buffer.write(chunk);
    pending.add(chunk);
    if (pending.length >= Limits.maxOutputFrameBytes) {
      _flush();
    } else {
      _flushTimer ??= Timer(coalesce, _flush);
    }
  }

  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final pending = _pending;
    if (pending == null || pending.isEmpty) return;
    final data = pending.takeBytes();
    final start = _pendingStart;
    for (final s in _subscribers.toList()) {
      s.onOutput(this, start, data);
    }
  }

  void _onOutputDone() {
    _flush();
    if (!_outputDone.isCompleted) _outputDone.complete();
  }

  void _onExit(ExitInfo info) {
    _exited = ExitStatus(code: info.code, signal: info.signal);
    _exitedAt = _clock();
    _flush();
    for (final s in _subscribers.toList()) {
      s.onExit(this, _exited!);
    }
  }
}
