import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../conn/connection.dart';
import '../i18n/strings.dart';
import '../interop/xterm.dart';

/// xterm.js wrapper: fit-to-container, pinch zoom, scroll-to-bottom and copy
/// overlays, notices, buffer-change signal for auto mode switching.
final class TerminalView implements TerminalSink {
  /// Mounts a terminal inside [container].
  TerminalView(
    web.HTMLElement container, {
    required this.strings,
    int fontSize = 14,
  }) : _container = container,
       _fontSize = fontSize {
    _terminal = Terminal(
      TerminalOptions(
        cursorBlink: true,
        fontSize: fontSize,
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
    _overlay = web.document.createElement('div') as web.HTMLElement
      ..className = 'term-overlay';
    _toBottom = _overlayButton(
      strings['toBottom'],
      () => _terminal.scrollToBottom(),
    );
    _copy = _overlayButton(strings['copy'], _copySelection);
    _overlay
      ..appendChild(_copy)
      ..appendChild(_toBottom);
    container.appendChild(_overlay);
    fit();
    web.window.addEventListener('resize', ((web.Event _) => fit()).toJS);
    final observer = web.ResizeObserver(
      ((JSArray<web.ResizeObserverEntry> _, web.ResizeObserver observer) =>
              fit())
          .toJS,
    );
    observer.observe(container);
    _bindTouch();
  }

  final web.HTMLElement _container;
  final Strings strings;
  late final Terminal _terminal;
  late final FitAddon _fit;
  late final web.HTMLElement _overlay;
  late final web.HTMLElement _toBottom;
  late final web.HTMLElement _copy;
  int _fontSize;

  /// Called with UTF-8 bytes typed by the user.
  void Function(Uint8List data)? onInput;

  /// Called when the terminal size changes.
  void Function(int cols, int rows)? onResize;

  /// Called when the active buffer switches between normal and alternate.
  void Function(bool alternate)? onAlternateScreen;

  /// Called after a pinch changed the font size.
  void Function(int fontSize)? onFontSizeChanged;

  /// Wires xterm.js events.
  void bind() {
    _terminal.onData(
      ((String data) {
        // Answers to queries replayed from scrollback are not user input.
        if (_replaying > 0) return;
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
    _terminal.buffer.onBufferChange(
      ((JSAny? _) {
        onAlternateScreen?.call(inAlternateScreen);
      }).toJS,
    );
    _terminal.onScroll(((JSAny? _) => _updateOverlay()).toJS);
    _terminal.onSelectionChange(((JSAny? _) => _updateOverlay()).toJS);
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

  /// DECCKM state, needed to encode arrow keys.
  bool get applicationCursor => _terminal.modes.applicationCursorKeysMode;

  /// Whether the shell enabled bracketed paste.
  bool get bracketedPaste => _terminal.modes.bracketedPasteMode;

  /// Current font size in CSS pixels.
  int get fontSize => _fontSize;
  set fontSize(int value) {
    _fontSize = value.clamp(8, 32);
    _terminal.options.fontSize = _fontSize;
    fit();
  }

  /// Scrolls by whole pages (negative = up).
  void scrollPages(int pages) => _terminal.scrollPages(pages);

  @override
  (int cols, int rows) get size => (_terminal.cols, _terminal.rows);

  /// Replay writes still being parsed; terminal answers are dropped while
  /// this is above zero.
  int _replaying = 0;

  @override
  void writeOutput(Uint8List data, {bool replay = false}) {
    if (!replay) {
      _terminal.write(data.toJS);
      return;
    }
    _replaying++;
    _terminal.write(data.toJS, (() => _replaying--).toJS);
  }

  @override
  void writeNotice(String text) =>
      _terminal.write('\r\n\x1b[1;33m[tp] $text\x1b[0m\r\n'.toJS);

  @override
  void clearAll() => _terminal.reset();

  void _updateOverlay() {
    final buffer = _terminal.buffer.active;
    final scrolledUp = buffer.viewportY < buffer.baseY;
    _toBottom.classList.toggle('hidden', !scrolledUp);
    _copy.classList.toggle('hidden', !_terminal.hasSelection());
  }

  void _copySelection() {
    if (!_terminal.hasSelection()) return;
    final text = _terminal.getSelection();
    web.window.navigator.clipboard.writeText(text);
    _terminal.clearSelection();
    _copy.textContent = strings['copied'];
    Timer(const Duration(milliseconds: 1200), () {
      _copy.textContent = strings['copy'];
    });
  }

  web.HTMLElement _overlayButton(String label, void Function() onTap) {
    final b = web.document.createElement('button') as web.HTMLElement
      ..className = 'term-overlay-btn hidden'
      ..textContent = label;
    b.addEventListener(
      'pointerdown',
      ((web.Event e) => e.preventDefault()).toJS,
    );
    b.addEventListener('click', ((web.Event _) => onTap()).toJS);
    return b;
  }

  /// Pinch with two fingers changes the font size (docs/16), not the page
  /// zoom. Single-finger gestures are left to xterm (scroll, select).
  void _bindTouch() {
    final pointers = <int, (double, double)>{};
    double? startDistance;
    var startSize = _fontSize;

    double distance() {
      final p = pointers.values.toList();
      final dx = p[0].$1 - p[1].$1;
      final dy = p[0].$2 - p[1].$2;
      return (dx * dx + dy * dy).sqrt();
    }

    _container.addEventListener(
      'pointerdown',
      ((web.PointerEvent e) {
        if (e.pointerType != 'touch') return;
        pointers[e.pointerId] = (e.clientX.toDouble(), e.clientY.toDouble());
        if (pointers.length == 2) {
          startDistance = distance();
          startSize = _fontSize;
        }
      }).toJS,
    );
    _container.addEventListener(
      'pointermove',
      ((web.PointerEvent e) {
        if (!pointers.containsKey(e.pointerId)) return;
        pointers[e.pointerId] = (e.clientX.toDouble(), e.clientY.toDouble());
        final start = startDistance;
        if (pointers.length == 2 && start != null && start > 0) {
          e.preventDefault();
          final next = (startSize * distance() / start).round().clamp(8, 32);
          if (next != _fontSize) {
            fontSize = next;
            onFontSizeChanged?.call(_fontSize);
          }
        }
      }).toJS,
    );
    void release(web.PointerEvent e) {
      pointers.remove(e.pointerId);
      if (pointers.length < 2) startDistance = null;
    }

    _container.addEventListener('pointerup', release.toJS);
    _container.addEventListener('pointercancel', release.toJS);
  }
}

extension on double {
  double sqrt() {
    final x = this;
    if (x <= 0) return 0;
    var guess = x / 2;
    for (var i = 0; i < 20; i++) {
      guess = (guess + x / guess) / 2;
    }
    return guess;
  }
}
