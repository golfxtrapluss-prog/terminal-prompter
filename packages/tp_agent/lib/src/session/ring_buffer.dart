import 'dart:math' as math;
import 'dart:typed_data';

/// Result of [RingBuffer.readFrom].
final class RingRead {
  /// Creates the result.
  const RingRead({required this.data, required this.startSeq, this.truncated});

  /// Bytes from [startSeq] up to the buffer's current `seq`.
  final Uint8List data;

  /// Sequence number of the first byte in [data].
  final int startSeq;

  /// Set when the requested position was already overwritten: bytes in
  /// `[from, to)` are lost. Maps to `attached.truncated` in docs/04.
  final ({int from, int to})? truncated;

  /// Sequence number just past the last byte in [data].
  int get endSeq => startSeq + data.length;
}

/// Fixed-capacity circular byte buffer with a monotonically increasing byte
/// sequence number (docs/02, ADR-006).
///
/// `seq` counts every byte ever written, so a client can resume from any
/// position regardless of how output was split into frames. Invariant: the
/// byte with sequence number `s` lives at index `s % capacity` while it is
/// retained.
final class RingBuffer {
  /// Creates a buffer retaining the last [capacity] bytes.
  RingBuffer(int capacity)
    : assert(capacity > 0, 'capacity must be positive'),
      _buf = Uint8List(capacity);

  final Uint8List _buf;
  int _seq = 0;
  int _length = 0;

  /// Maximum number of retained bytes.
  int get capacity => _buf.length;

  /// Sequence number the next written byte will get (= total bytes written).
  int get seq => _seq;

  /// Number of bytes currently retained.
  int get length => _length;

  /// Sequence number of the oldest retained byte.
  int get oldestSeq => _seq - _length;

  /// Appends [data]. If it is larger than [capacity] only its tail is kept,
  /// but [seq] still advances by the full length.
  void write(List<int> data) {
    final total = data.length;
    if (total == 0) return;
    final cap = capacity;
    final keep = math.min(total, cap);
    final skip = total - keep;
    var pos = (_seq + skip) % cap;
    final first = math.min(keep, cap - pos);
    _buf.setRange(pos, pos + first, data, skip);
    if (first < keep) {
      pos = 0;
      _buf.setRange(0, keep - first, data, skip + first);
    }
    _seq += total;
    _length = math.min(cap, _length + total);
  }

  /// Returns everything from [fromSeq] to [seq]. A position older than
  /// [oldestSeq] yields what is left plus a `truncated` range; a position
  /// beyond [seq] yields nothing starting at [seq].
  RingRead readFrom(int fromSeq) {
    if (fromSeq < 0) throw RangeError.range(fromSeq, 0, _seq, 'fromSeq');
    var start = math.min(fromSeq, _seq);
    ({int from, int to})? truncated;
    final oldest = oldestSeq;
    if (start < oldest) {
      truncated = (from: start, to: oldest);
      start = oldest;
    }
    final n = _seq - start;
    final out = Uint8List(n);
    if (n > 0) {
      final pos = start % capacity;
      final first = math.min(n, capacity - pos);
      out.setRange(0, first, _buf, pos);
      if (first < n) out.setRange(first, n, _buf, 0);
    }
    return RingRead(data: out, startSeq: start, truncated: truncated);
  }
}
