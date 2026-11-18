import 'dart:io';

import '../log_util.dart';

/// Sets `key = value` inside `[section]` of a TOML file by editing lines,
/// so comments and layout survive. [value] must already be a TOML literal
/// (use [tomlString]). Adds the key or the section when missing. The file
/// is rewritten atomically with mode 0600 (it holds the password hash).
void setTomlValue(String path, String section, String key, String value) {
  final lines = File(path).readAsLinesSync();
  final header = RegExp(r'^\s*\[([^\]]+)\]\s*(#.*)?$');
  final keyLine = RegExp('^\\s*${RegExp.escape(key)}\\s*=');
  var inSection = false;
  var sectionStart = -1;
  var sectionEnd = lines.length;
  for (var i = 0; i < lines.length; i++) {
    final m = header.firstMatch(lines[i]);
    if (m != null) {
      if (inSection) {
        sectionEnd = i;
        break;
      }
      if (m.group(1)!.trim() == section) {
        inSection = true;
        sectionStart = i;
      }
      continue;
    }
    if (inSection && keyLine.hasMatch(lines[i])) {
      lines[i] = '$key = $value';
      _write(path, lines);
      return;
    }
  }
  if (sectionStart < 0) {
    lines
      ..add('')
      ..add('[$section]')
      ..add('$key = $value');
  } else {
    // Insert after the last non-blank line of the section.
    var at = sectionEnd;
    while (at > sectionStart + 1 && lines[at - 1].trim().isEmpty) {
      at--;
    }
    lines.insert(at, '$key = $value');
  }
  _write(path, lines);
}

/// A TOML literal string (single quotes) when possible, else a basic one.
String tomlString(String s) {
  if (!s.contains("'") && !s.contains('\n')) return "'$s'";
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');
  return '"$escaped"';
}

void _write(String path, List<String> lines) =>
    writePrivateFile(path, '${lines.join('\n')}\n');
