import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'errors.dart';
import 'libc.dart' as libc;
import 'reader.dart';

/// How a PTY child process ended.
final class ExitInfo {
  /// Creates exit information; exactly one of [code] or [signal] is set.
  const ExitInfo({this.code, this.signal});

  /// Converts a `Process.exitCode` value (negative means killed by signal).
  factory ExitInfo.fromProcessExitCode(int raw) =>
      raw < 0 ? ExitInfo(signal: -raw) : ExitInfo(code: raw);

  /// Exit status when the process exited normally.
  final int? code;

  /// Signal number when the process was killed by a signal.
  final int? signal;

  @override
  String toString() => signal != null ? 'signal $signal' : 'exit $code';
}

/// Selected fields of `/proc/<pid>/stat`.
final class ProcStat {
  /// Creates the record.
  const ProcStat({
    required this.pid,
    required this.state,
    required this.ppid,
    required this.pgid,
    required this.sid,
    required this.ttyNr,
  });

  /// Process id.
  final int pid;

  /// One-letter state (`R`, `S`, `Z`, ...).
  final String state;

  /// Parent process id.
  final int ppid;

  /// Process group id.
  final int pgid;

  /// Session id.
  final int sid;

  /// Controlling terminal device number, 0 if none.
  final int ttyNr;

  /// True for a zombie waiting to be reaped.
  bool get isZombie => state == 'Z';
}

/// Launcher run by `/bin/sh`. The shell opens the slave as stdio, `setsid -c`
/// creates a new session with the PTY as controlling terminal, then execs the
/// command. The chain sh -> setsid -> command keeps a single pid because `sh`
/// is not a process-group leader (docs/02, step 4).
const String _launcher = r'exec setsid -c "$0" "$@" <"$TP_PTS" >"$TP_PTS" 2>&1';

const int _ptsNameLength = 128;
const int _writeChunk = 4096;
const int _maxDimension = 0xFFFF;

/// A shell (or any program) running in its own pseudo-terminal.
///
/// Lifecycle: [start] -> use [output], [write], [resize] -> the child exits
/// ([exited]) or is ended with [terminate] -> [close] releases descriptors.
/// [close] never kills the process on its own, but closing the master hangs
/// up the terminal, which normally makes an interactive shell exit.
final class PtyProcess {
  PtyProcess._({
    required int master,
    required this.ptsPath,
    required Process process,
    required int wakeRead,
    required int wakeWrite,
    required StreamController<Uint8List> output,
    required Completer<ReaderDone> readerDone,
    required int cols,
    required int rows,
  }) : _master = master,
       _process = process,
       _wakeRead = wakeRead,
       _wakeWrite = wakeWrite,
       _output = output,
       _readerDone = readerDone,
       _cols = cols,
       _rows = rows,
       exited = process.exitCode.then(ExitInfo.fromProcessExitCode);

  /// Opens a PTY pair, starts [command] in a new session attached to it and
  /// begins reading its output.
  ///
  /// Requires `/bin/sh` and `setsid` with `-c` support (util-linux or
  /// BusyBox). If `setsid` is missing the child exits with status 127.
  static Future<PtyProcess> start({
    required String command,
    List<String> arguments = const [],
    Map<String, String> environment = const {},
    String? workingDirectory,
    int cols = 80,
    int rows = 24,
  }) async {
    _checkDimensions(cols, rows);
    final (master, ptsPath) = _openPty();
    var wakeRead = -1;
    var wakeWrite = -1;
    try {
      _setWinSize(master, cols, rows);
      (wakeRead, wakeWrite) = _openPipe();

      final process = await Process.start(
        '/bin/sh',
        ['-c', _launcher, command, ...arguments],
        environment: {...environment, 'TP_PTS': ptsPath},
        workingDirectory: workingDirectory,
      );
      // The child's stdio is redirected to the PTY, so Dart's pipes are
      // unused. Close/drain them so nothing leaks or blocks.
      unawaited(process.stdin.close().then<void>((_) {}, onError: (_) {}));
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());

      final output = StreamController<Uint8List>();
      final readerDone = Completer<ReaderDone>();
      final port = ReceivePort('pty-reader-${process.pid}');
      final exitPort = ReceivePort('pty-reader-exit-${process.pid}');

      void finish(ReaderDone done) {
        if (!readerDone.isCompleted) readerDone.complete(done);
        port.close();
        exitPort.close();
        if (!output.isClosed) unawaited(output.close());
      }

      port.listen((Object? message) {
        switch (message) {
          case final TransferableTypedData data:
            output.add(data.materialize().asUint8List());
          case final ReaderDone done:
            finish(done);
        }
      });
      // Safety net: if the isolate dies without reporting, close the stream.
      exitPort.listen((_) => finish(const ReaderDone(ReaderReason.error)));

      try {
        await Isolate.spawn<ReaderArgs>(
          readerMain,
          ReaderArgs(masterFd: master, wakeFd: wakeRead, port: port.sendPort),
          debugName: 'pty-reader-${process.pid}',
          onExit: exitPort.sendPort,
        );
      } on Object {
        finish(const ReaderDone(ReaderReason.error));
        process.kill(ProcessSignal.sigkill);
        rethrow;
      }

      return PtyProcess._(
        master: master,
        ptsPath: ptsPath,
        process: process,
        wakeRead: wakeRead,
        wakeWrite: wakeWrite,
        output: output,
        readerDone: readerDone,
        cols: cols,
        rows: rows,
      );
    } on Object {
      libc.close(master);
      if (wakeRead >= 0) libc.close(wakeRead);
      if (wakeWrite >= 0) libc.close(wakeWrite);
      rethrow;
    }
  }

  final int _master;
  final Process _process;
  final int _wakeRead;
  final int _wakeWrite;
  final StreamController<Uint8List> _output;
  final Completer<ReaderDone> _readerDone;
  int _cols;
  int _rows;
  bool _closed = false;

  /// Path of the slave device, e.g. `/dev/pts/7`.
  final String ptsPath;

  /// Completes when the command exits. Children it left behind may still be
  /// running; see [sessionPids] and [terminate].
  final Future<ExitInfo> exited;

  /// Pid of the command. It is also the session id and process-group id.
  int get pid => _process.pid;

  /// Current terminal width in columns.
  int get cols => _cols;

  /// Current terminal height in rows.
  int get rows => _rows;

  /// True after [close].
  bool get isClosed => _closed;

  /// Raw bytes written by the child to its terminal. Single-subscription.
  /// Closes when the slave side is gone or after [close].
  Stream<Uint8List> get output => _output.stream;

  /// Writes [data] to the terminal input, in 4 KB chunks so a large paste
  /// never blocks the event loop. If the child stops reading, the write
  /// fails with [PtyWriteTimeout] after [timeout].
  Future<void> write(
    List<int> data, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_closed) throw const PtyClosedError();
    if (data.isEmpty) return;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final buf = malloc<Uint8>(_writeChunk);
    final stalled = Stopwatch();
    try {
      var offset = 0;
      while (offset < bytes.length) {
        if (_closed) throw const PtyClosedError();
        final n = math.min(_writeChunk, bytes.length - offset);
        buf.asTypedList(n).setRange(0, n, bytes, offset);
        final written = libc.write(_master, buf, n);
        if (written > 0) {
          offset += written;
          stalled.reset();
          if (offset < bytes.length) await Future<void>.delayed(Duration.zero);
          continue;
        }
        final e = written < 0 ? libc.errno : libc.eagain;
        if (e != libc.eagain && e != libc.eintr) {
          throw PtySyscallError('write', e);
        }
        if (!stalled.isRunning) stalled.start();
        if (stalled.elapsed > timeout) {
          throw PtyWriteTimeout(offset, bytes.length);
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    } finally {
      malloc.free(buf);
    }
  }

  /// Changes the terminal size. The kernel sends `SIGWINCH` to the
  /// foreground process group.
  void resize(int cols, int rows) {
    if (_closed) throw const PtyClosedError();
    _checkDimensions(cols, rows);
    _setWinSize(_master, cols, rows);
    _cols = cols;
    _rows = rows;
  }

  /// Sends [signal] to every process in the child's session: the command's
  /// own process group first, then any other group (background jobs) found
  /// in `/proc`. Returns the number of processes signalled.
  int kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    final signo = signal.signalNumber;
    var count = 0;
    if (libc.kill(-pid, signo) == 0) count++;
    for (final other in sessionPids()) {
      if (other == pid) continue;
      if (libc.kill(other, signo) == 0) count++;
    }
    return count;
  }

  /// Ends the session: `SIGTERM` to everything, `SIGKILL` to whatever is
  /// still alive after [grace]. Completes with the command's [ExitInfo] once
  /// no live process remains in the session.
  Future<ExitInfo> terminate({
    Duration grace = const Duration(seconds: 2),
  }) async {
    kill();
    final result = await Future.any<ExitInfo?>([
      exited,
      Future<ExitInfo?>.delayed(grace, () => null),
    ]);
    if (result == null) kill(ProcessSignal.sigkill);
    final info = await exited;
    if (!await _waitForSessionEmpty(grace)) {
      kill(ProcessSignal.sigkill);
      await _waitForSessionEmpty(grace);
    }
    return info;
  }

  /// Stops the reader and releases the PTY and pipe descriptors. Safe to call
  /// more than once. Closing the master hangs up the terminal.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final one = malloc<Uint8>(1);
    try {
      one.value = 1;
      libc.write(_wakeWrite, one, 1);
    } finally {
      malloc.free(one);
    }
    await _readerDone.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => const ReaderDone(ReaderReason.error),
    );
    libc.close(_master);
    libc.close(_wakeRead);
    libc.close(_wakeWrite);
    if (!_output.isClosed) await _output.close();
  }

  /// Pids of live (non-zombie) processes whose session id is [pid], the
  /// command itself included. Reads `/proc`.
  List<int> sessionPids() {
    final result = <int>[];
    for (final entry in Directory('/proc').listSync(followLinks: false)) {
      final candidate = int.tryParse(
        entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => ''),
      );
      if (candidate == null) continue;
      final stat = readProcStat(candidate);
      if (stat != null && stat.sid == pid && !stat.isZombie) {
        result.add(candidate);
      }
    }
    return result..sort();
  }

  /// Parses `/proc/<pid>/stat`, or returns null if the process is gone.
  static ProcStat? readProcStat(int pid) {
    final String content;
    try {
      content = File('/proc/$pid/stat').readAsStringSync();
    } on FileSystemException {
      return null; // Process exited between listing and reading.
    }
    // Format: "pid (comm) state ppid pgrp session tty_nr ...". comm may
    // contain spaces and parentheses, so split after the last ')'.
    final close = content.lastIndexOf(')');
    if (close < 0) return null;
    final fields = content.substring(close + 2).split(' ');
    if (fields.length < 5) return null;
    return ProcStat(
      pid: pid,
      state: fields[0],
      ppid: int.parse(fields[1]),
      pgid: int.parse(fields[2]),
      sid: int.parse(fields[3]),
      ttyNr: int.parse(fields[4]),
    );
  }

  Future<bool> _waitForSessionEmpty(Duration timeout) async {
    final sw = Stopwatch()..start();
    while (sessionPids().isNotEmpty) {
      if (sw.elapsed > timeout) return false;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return true;
  }

  static void _checkDimensions(int cols, int rows) {
    if (cols <= 0 ||
        rows <= 0 ||
        cols > _maxDimension ||
        rows > _maxDimension) {
      throw ArgumentError('cols/rows must be in 1..$_maxDimension');
    }
  }

  static (int, String) _openPty() {
    final master = libc.posixOpenpt(
      libc.oRdwr | libc.oNoctty | libc.oCloexec | libc.oNonblock,
    );
    if (master < 0) throw PtySyscallError('posix_openpt', libc.errno);
    try {
      if (libc.grantpt(master) != 0) {
        throw PtySyscallError('grantpt', libc.errno);
      }
      if (libc.unlockpt(master) != 0) {
        throw PtySyscallError('unlockpt', libc.errno);
      }
      final buf = malloc<Char>(_ptsNameLength);
      try {
        final rc = libc.ptsnameR(master, buf, _ptsNameLength);
        if (rc != 0) throw PtySyscallError('ptsname_r', rc);
        return (master, buf.cast<Utf8>().toDartString());
      } finally {
        malloc.free(buf);
      }
    } on Object {
      libc.close(master);
      rethrow;
    }
  }

  static (int, int) _openPipe() {
    final fds = malloc<Int32>(2);
    try {
      if (libc.pipe2(fds, libc.oCloexec | libc.oNonblock) != 0) {
        throw PtySyscallError('pipe2', libc.errno);
      }
      return (fds[0], fds[1]);
    } finally {
      malloc.free(fds);
    }
  }

  static void _setWinSize(int fd, int cols, int rows) {
    final ws = calloc<libc.WinSize>();
    try {
      ws.ref.wsCol = cols;
      ws.ref.wsRow = rows;
      if (libc.ioctlWinSize(fd, libc.tiocswinsz, ws) != 0) {
        throw PtySyscallError('ioctl(TIOCSWINSZ)', libc.errno);
      }
    } finally {
      calloc.free(ws);
    }
  }
}
