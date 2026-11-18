import 'dart:convert';

import '../conn/transport.dart';

/// A named command with `{{variable}}` placeholders (docs/03).
final class Snippet {
  const Snippet({required this.name, required this.command});

  factory Snippet.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final command = json['command'];
    if (name is! String || command is! String) {
      throw const FormatException('snippet needs name and command');
    }
    return Snippet(name: name, command: command);
  }

  final String name;
  final String command;

  /// Variable names in order of first appearance.
  List<String> get variables {
    final seen = <String>[];
    for (final m in _variablePattern.allMatches(command)) {
      final v = m.group(1)!;
      if (!seen.contains(v)) seen.add(v);
    }
    return seen;
  }

  /// Fills placeholders from [values]; missing ones are left as-is.
  String expand(Map<String, String> values) => command.replaceAllMapped(
    _variablePattern,
    (m) => values[m.group(1)!] ?? m.group(0)!,
  );

  Map<String, Object?> toJson() => {'name': name, 'command': command};

  static final RegExp _variablePattern = RegExp(
    r'\{\{\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}',
  );
}

/// Snippet library persisted per agent, with JSON export/import.
final class SnippetLibrary {
  SnippetLibrary(this._store) {
    final raw = _store.read(_key);
    if (raw != null) {
      try {
        importJson(raw, replace: true, persist: false);
      } on FormatException {
        _store.remove(_key);
      }
    }
  }

  static const String _key = 'tp.snippets';

  final KeyValueStore _store;
  final List<Snippet> _items = [];

  List<Snippet> get items => List.unmodifiable(_items);

  /// Adds or replaces (by name).
  void save(Snippet snippet) {
    _items.removeWhere((s) => s.name == snippet.name);
    _items.add(snippet);
    _persist();
  }

  void remove(String name) {
    _items.removeWhere((s) => s.name == name);
    _persist();
  }

  /// JSON array of snippets.
  String exportJson() => const JsonEncoder.withIndent(
    '  ',
  ).convert([for (final s in _items) s.toJson()]);

  /// Imports a JSON array; merges by name unless [replace].
  void importJson(String json, {bool replace = false, bool persist = true}) {
    final decoded = jsonDecode(json);
    if (decoded is! List) throw const FormatException('expected a JSON array');
    final parsed = [
      for (final item in decoded)
        if (item is Map<String, Object?>)
          Snippet.fromJson(item)
        else
          throw const FormatException('bad snippet'),
    ];
    if (replace) _items.clear();
    for (final s in parsed) {
      _items.removeWhere((e) => e.name == s.name);
      _items.add(s);
    }
    if (persist) _persist();
  }

  void _persist() =>
      _store.write(_key, jsonEncode([for (final s in _items) s.toJson()]));
}
