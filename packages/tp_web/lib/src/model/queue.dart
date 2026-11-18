import 'dart:typed_data';

/// Delivery state of a Prompter command (docs/03 "Leveringsstatus").
enum DeliveryStatus {
  /// Waiting for the network.
  queued,

  /// Sent, waiting for `ack_in`.
  sent,

  /// Written to the PTY.
  acked,

  /// Older than the queue limit; needs the user's confirmation again.
  stale,
}

/// One command the user sent from the Prompter.
final class PendingCommand {
  PendingCommand({
    required this.text,
    required this.bytes,
    required this.createdAt,
  });

  /// What the user typed (for display and history).
  final String text;

  /// Exact bytes to write (with bracketed paste and `\r`).
  final Uint8List bytes;

  /// When it was submitted.
  final DateTime createdAt;

  /// `client_msg_id` once sent.
  int? msgId;

  /// Current state.
  DeliveryStatus status = DeliveryStatus.queued;

  /// The user re-confirmed a stale command; age no longer matters.
  bool confirmed = false;
}

/// Offline queue: commands submitted while disconnected wait, are flushed on
/// reconnect, and anything older than [maxAge] must be confirmed again.
final class CommandQueue {
  CommandQueue({
    this.maxAge = const Duration(seconds: 60),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration maxAge;
  final DateTime Function() _clock;
  final List<PendingCommand> _items = [];

  /// Recent commands, oldest first (queued, sent and acked).
  List<PendingCommand> get items => List.unmodifiable(_items);

  /// Commands still waiting for the network.
  Iterable<PendingCommand> get waiting =>
      _items.where((c) => c.status == DeliveryStatus.queued);

  PendingCommand enqueue(String text, Uint8List bytes) {
    final cmd = PendingCommand(text: text, bytes: bytes, createdAt: _clock());
    _items.add(cmd);
    while (_items.length > 50) {
      _items.removeAt(0);
    }
    return cmd;
  }

  /// Marks queued commands older than [maxAge] as stale and returns those
  /// still safe to send automatically.
  List<PendingCommand> takeSendable() {
    final now = _clock();
    final out = <PendingCommand>[];
    for (final c in _items) {
      if (c.status != DeliveryStatus.queued) continue;
      if (!c.confirmed && now.difference(c.createdAt) > maxAge) {
        c.status = DeliveryStatus.stale;
      } else {
        out.add(c);
      }
    }
    return out;
  }

  /// Re-arms a stale command after the user confirmed it.
  void confirm(PendingCommand cmd) {
    if (cmd.status == DeliveryStatus.stale) {
      cmd.status = DeliveryStatus.queued;
      cmd.confirmed = true;
    }
  }

  /// Drops a stale or queued command.
  void discard(PendingCommand cmd) => _items.remove(cmd);

  /// Marks the command with [msgId] as acknowledged.
  bool ack(int msgId) {
    for (final c in _items) {
      if (c.msgId == msgId && c.status == DeliveryStatus.sent) {
        c.status = DeliveryStatus.acked;
        return true;
      }
    }
    return false;
  }
}
