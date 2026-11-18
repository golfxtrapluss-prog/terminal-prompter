import 'dart:convert';
import 'dart:typed_data';

import '../conn/transport.dart';

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

  Map<String, Object?> toJson() => {
    'text': text,
    'bytes': base64Encode(bytes),
    'created': createdAt.toUtc().toIso8601String(),
  };

  static PendingCommand? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final text = json['text'];
    final bytes = json['bytes'];
    final created = json['created'];
    if (text is! String || bytes is! String || created is! String) return null;
    final at = DateTime.tryParse(created);
    if (at == null) return null;
    try {
      return PendingCommand(
        text: text,
        bytes: base64Decode(bytes),
        createdAt: at,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Offline queue: commands submitted while disconnected wait, are flushed on
/// reconnect, and anything older than [maxAge] must be confirmed again.
///
/// Commands not yet sent are persisted in [store] so they survive a page
/// reload (for example when the agent was updated while the link was down).
final class CommandQueue {
  CommandQueue({
    this.maxAge = const Duration(seconds: 60),
    DateTime Function()? clock,
    KeyValueStore? store,
  }) : _clock = clock ?? DateTime.now,
       _store = store {
    final raw = store?.read(_key);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          final cmd = PendingCommand.fromJson(item);
          if (cmd != null) _items.add(cmd);
        }
      }
    } on FormatException {
      store?.remove(_key);
    }
  }

  static const String _key = 'tp.queue';

  final Duration maxAge;
  final DateTime Function() _clock;
  final KeyValueStore? _store;
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
    _persist();
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

  /// Records that [cmd] was handed to the connection as [msgId].
  void markSent(PendingCommand cmd, int msgId) {
    cmd
      ..msgId = msgId
      ..status = DeliveryStatus.sent;
    _persist();
  }

  /// Re-arms a stale command after the user confirmed it.
  void confirm(PendingCommand cmd) {
    if (cmd.status == DeliveryStatus.stale) {
      cmd.status = DeliveryStatus.queued;
      cmd.confirmed = true;
    }
  }

  /// Drops a stale or queued command.
  void discard(PendingCommand cmd) {
    _items.remove(cmd);
    _persist();
  }

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

  /// Only commands that never reached the connection are persisted; sent
  /// ones are covered by the connection's own resend of unacked input.
  void _persist() {
    final store = _store;
    if (store == null) return;
    final pending = [
      for (final c in _items)
        if (c.status == DeliveryStatus.queued ||
            c.status == DeliveryStatus.stale)
          c.toJson(),
    ];
    if (pending.isEmpty) {
      store.remove(_key);
    } else {
      store.write(_key, jsonEncode(pending));
    }
  }
}
