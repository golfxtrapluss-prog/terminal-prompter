import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../conn/connection.dart';
import '../interop/xterm.dart';

/// xterm.js wrapper: Raw mode keyboard handling, fit-to-container, notices.
final class TerminalView implements TerminalSink {
  /// Mounts a terminal inside [container].
  TerminalView(web.HTMLElement container) : _container = container {
    _terminal = Terminal(
      TerminalOptions(
        cursorBlink: true,
        fontSize: 14,
        fontFamily:
            'ui-monospace, "JetBrains Mono", Menlo, Consolas, monospace',
        scrollback: 5000,
        allowProposedApi: true,
        theme: TerminalTheme(
          background: '#0d1117',
          foreground: '#e6edf3',
          cursor: '#58a6ff',
          selectionBackground: '#264f78',
        ),
      ),
    );
    _fit = FitAddon();
    _terminal
      ..loadAddon(_fit)
      ..loadAddon(WebLinksAddon())
      ..loadAddon(Unicode11Addon())
      ..loadAddon(SearchAddon());
    _terminal.unicode.activeVersion = '11';
    _terminal.open(container);
    fit();
    web.window.addEventListener('resize', ((web.Event _) => fit()).toJS);
  }

  final web.HTMLElement _container;
  late final Terminal _terminal;
  late final FitAddon _fit;

  /// Called with UTF-8 bytes typed by the user.
  void Function(Uint8List data)? onInput;

  /// Called when the terminal size changes.
  void Function(int cols, int rows)? onResize;

  /// Wires xterm.js events to [onInput] and [onResize].
  void bind() {
    _terminal.onData(
      ((String data) {
        onInput?.call(Connection.encodeInput(data));
      }).toJS,
    );
    _terminal.onBinary(
      ((String data) {
        onInput?.call(Uint8List.fromList(data.codeUnits));
      }).toJS,
    );
    _terminal.onResize(
      ((ResizeEvent event) {
        onResize?.call(event.cols, event.rows);
      }).toJS,
    );
  }

  /// Resizes the terminal to fill its container.
  void fit() {
    if (_container.clientWidth == 0 || _container.clientHeight == 0) return;
    _fit.fit();
  }

  /// Focuses the terminal for typing.
  void focus() => _terminal.focus();

  /// True while a full-screen program (vim, htop) owns the screen.
  bool get inAlternateScreen => _terminal.buffer.active.type == 'alternate';

  @override
  (int cols, int rows) get size => (_terminal.cols, _terminal.rows);

  @override
  void writeOutput(Uint8List data) => _terminal.write(data.toJS);

  @override
  void writeNotice(String text) =>
      _terminal.write('\r\n\x1b[1;33m[tp] $text\x1b[0m\r\n'.toJS);

  @override
  void clearAll() => _terminal.reset();
}
