import 'dart:collection';

import 'limits.dart';

/// Remembers the last `Limits.inputIdHistory` `client_msg_id`s per client
/// instance so an input frame resent after a reconnect is written only once
/// (docs/04 "Input-idempotens"). Used by the agent per session.
final class InputDeduper {
  /// Creates an empty deduper.
  InputDeduper({this.capacity = Limits.inputIdHistory});

  /// Ids remembered per instance.
  final int capacity;

  final Map<String, _Window> _windows = {};

  /// Records [id] for [instance]. Returns true if it was already seen.
  bool isDuplicate(String instance, int id) {
    final window = _windows.putIfAbsent(instance, _Window.new);
    if (window.ids.contains(id)) return true;
    window.ids.add(id);
    window.order.addLast(id);
    while (window.order.length > capacity) {
      window.ids.remove(window.order.removeFirst());
    }
    return false;
  }

  /// Forgets everything about [instance].
  void forget(String instance) => _windows.remove(instance);

  /// Number of instances tracked.
  int get instanceCount => _windows.length;
}

final class _Window {
  final Set<int> ids = {};
  final Queue<int> order = Queue<int>();
}
