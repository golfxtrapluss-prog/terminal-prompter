import 'dart:convert';
import 'dart:typed_data';

/// Turns Prompter text into the bytes written to the PTY (docs/03).
///
/// Multi-line text is wrapped in bracketed paste when the shell has enabled
/// it, so the shell treats it as one unit instead of running each line as it
/// arrives. A trailing carriage return runs the command.
abstract final class PrompterEncoding {
  static const String pasteStart = '\x1b[200~';
  static const String pasteEnd = '\x1b[201~';

  static Uint8List encodeCommand(String text, {required bool bracketedPaste}) {
    final normalised = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final multiLine = normalised.contains('\n');
    final body = multiLine ? normalised.replaceAll('\n', '\r') : normalised;
    final wrapped = multiLine && bracketedPaste
        ? '$pasteStart$body$pasteEnd'
        : body;
    return utf8.encode('$wrapped\r');
  }
}

/// Tracks whether the shell has bracketed paste on by watching output for
/// `ESC[?2004h` / `ESC[?2004l`, and whether a full-screen program owns the
/// screen (`ESC[?1049h` / `ESC[?1049l`), across chunk boundaries.
final class TerminalModeTracker {
  bool bracketedPaste = false;
  bool alternateScreen = false;
  bool applicationCursor = false;
  String _carry = '';

  static final RegExp _mode = RegExp(r'\x1b\[\?(\d+(?:;\d+)*)([hl])');

  /// Feeds output bytes (decoded leniently).
  void feed(Uint8List data) {
    final text = _carry + latin1.decode(data);
    var last = 0;
    for (final m in _mode.allMatches(text)) {
      final on = m.group(2) == 'h';
      for (final n in m.group(1)!.split(';')) {
        switch (n) {
          case '2004':
            bracketedPaste = on;
          case '1049' || '47' || '1047':
            alternateScreen = on;
          case '1':
            applicationCursor = on;
        }
      }
      last = m.end;
    }
    // Keep a possible partial escape sequence for the next chunk.
    final tailStart = text.lastIndexOf('\x1b');
    _carry = tailStart >= last && text.length - tailStart < 16
        ? text.substring(tailStart)
        : '';
  }
}
