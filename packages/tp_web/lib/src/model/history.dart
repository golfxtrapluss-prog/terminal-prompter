import 'dart:convert';

import '../conn/transport.dart';

/// Command history for the Prompter (docs/03): newest last, consecutive
/// duplicates collapsed, persisted per agent through a [KeyValueStore].
final class CommandHistory {
  /// Loads history from [store].
  CommandHistory(this._store, {this.capacity = 500}) {
    final raw = _store.read(_key);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) _items.addAll(decoded.whereType<String>());
      } on FormatException {
        _store.remove(_key); // Corrupt entry: start over.
      }
    }
    _cursor = _items.length;
  }

  static const String _key = 'tp.history';

  final KeyValueStore _store;

  /// Maximum entries kept.
  final int capacity;

  final List<String> _items = [];
  int _cursor = 0;
  String _draft = '';

  /// Entries, oldest first.
  List<String> get items => List.unmodifiable(_items);

  /// Records a sent command and resets navigation.
  void add(String command) {
    final trimmed = command.trimRight();
    if (trimmed.isEmpty) return;
    if (_items.isNotEmpty && _items.last == trimmed) {
      _resetCursor();
      return;
    }
    _items.add(trimmed);
    while (_items.length > capacity) {
      _items.removeAt(0);
    }
    _resetCursor();
    _store.write(_key, jsonEncode(_items));
  }

  /// Moves one entry back from the current position. [draft] is what the
  /// field holds now, restored when navigating past the newest entry.
  String? previous(String draft) {
    if (_items.isEmpty || _cursor == 0) return null;
    if (_cursor == _items.length) _draft = draft;
    _cursor--;
    return _items[_cursor];
  }

  /// Moves one entry forward; returns the saved draft after the newest.
  String? next() {
    if (_cursor >= _items.length) return null;
    _cursor++;
    return _cursor == _items.length ? _draft : _items[_cursor];
  }

  /// Newest entries containing [query] (case-insensitive), newest first.
  List<String> search(String query, {int limit = 20}) {
    final q = query.toLowerCase();
    final out = <String>[];
    for (var i = _items.length - 1; i >= 0 && out.length < limit; i--) {
      if (_items[i].toLowerCase().contains(q)) out.add(_items[i]);
    }
    return out;
  }

  /// Clears everything.
  void clear() {
    _items.clear();
    _resetCursor();
    _store.remove(_key);
  }

  void _resetCursor() {
    _cursor = _items.length;
    _draft = '';
  }
}
