/// Errors raised by the PTY layer.
sealed class PtyError implements Exception {
  const PtyError(this.message);

  /// Human-readable description.
  final String message;

  @override
  String toString() => 'PtyError: $message';
}

/// A libc call failed; [errno] carries the C error number.
final class PtySyscallError extends PtyError {
  PtySyscallError(this.call, this.errno) : super('$call failed (errno $errno)');

  /// Name of the failing call, e.g. `posix_openpt`.
  final String call;

  /// C `errno` value at the time of failure.
  final int errno;
}

/// An operation was attempted on a PTY that has been closed.
final class PtyClosedError extends PtyError {
  const PtyClosedError() : super('PTY is closed');
}

/// A write could not make progress because the child stopped reading its
/// terminal (the kernel input buffer stayed full for the whole timeout).
final class PtyWriteTimeout extends PtyError {
  PtyWriteTimeout(this.writtenBytes, this.totalBytes)
    : super('write stalled after $writtenBytes of $totalBytes bytes');

  /// Bytes delivered before the stall.
  final int writtenBytes;

  /// Bytes requested.
  final int totalBytes;
}
