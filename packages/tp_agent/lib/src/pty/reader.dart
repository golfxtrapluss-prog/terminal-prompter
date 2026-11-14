import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'libc.dart' as libc;

/// Arguments for [readerMain]. Must be sendable across isolates.
final class ReaderArgs {
  /// Creates the arguments.
  const ReaderArgs({
    required this.masterFd,
    required this.wakeFd,
    required this.port,
  });

  /// PTY master file descriptor to read from.
  final int masterFd;

  /// Read end of the wake pipe; any byte written to it stops the reader.
  final int wakeFd;

  /// Where output chunks and the final [ReaderDone] are sent.
  final SendPort port;
}

/// Why the reader stopped.
enum ReaderReason {
  /// The slave side closed (child exited): `read` returned 0 or `EIO`.
  eof,

  /// The owner asked the reader to stop through the wake pipe.
  stopped,

  /// An unexpected `errno`; see [ReaderDone.errno].
  error,
}

/// Final message from the reader isolate.
final class ReaderDone {
  /// Creates the message.
  const ReaderDone(this.reason, {this.errno = 0});

  /// Why the reader stopped.
  final ReaderReason reason;

  /// `errno` for [ReaderReason.error], otherwise 0.
  final int errno;
}

/// Size of the native read buffer.
const int readBufferSize = 32 * 1024;

/// Entry point of the reader isolate.
///
/// Blocks in `poll` on the PTY master and the wake pipe. Output is forwarded
/// as [TransferableTypedData] (one copy out of native memory, then zero-copy
/// transfer). The isolate exits after sending [ReaderDone].
void readerMain(ReaderArgs args) {
  final buf = malloc<Uint8>(readBufferSize);
  final fds = calloc<libc.PollFd>(2);
  try {
    fds[0].fd = args.masterFd;
    fds[0].events = libc.pollIn;
    fds[1].fd = args.wakeFd;
    fds[1].events = libc.pollIn;

    while (true) {
      fds[0].revents = 0;
      fds[1].revents = 0;
      final ready = libc.poll(fds, 2, -1);
      if (ready < 0) {
        final e = libc.errno;
        if (e == libc.eintr) continue;
        args.port.send(ReaderDone(ReaderReason.error, errno: e));
        return;
      }
      if (fds[1].revents != 0) {
        args.port.send(const ReaderDone(ReaderReason.stopped));
        return;
      }
      if (fds[0].revents == 0) continue;

      // POLLHUP may arrive together with buffered data: always try to read
      // first so nothing is lost before the EIO that follows.
      final n = libc.read(args.masterFd, buf, readBufferSize);
      if (n > 0) {
        args.port.send(TransferableTypedData.fromList([buf.asTypedList(n)]));
        continue;
      }
      if (n == 0) {
        args.port.send(const ReaderDone(ReaderReason.eof));
        return;
      }
      final e = libc.errno;
      if (e == libc.eintr || e == libc.eagain) continue;
      args.port.send(
        ReaderDone(
          e == libc.eio ? ReaderReason.eof : ReaderReason.error,
          errno: e,
        ),
      );
      return;
    }
  } finally {
    malloc.free(buf);
    calloc.free(fds);
  }
}
