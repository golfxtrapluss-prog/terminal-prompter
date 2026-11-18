/// `dart:js_interop` bindings for the vendored xterm.js 6 UMD builds.
///
/// The UMD bundle of `@xterm/xterm` exports `Terminal` as a global class;
/// each addon bundle exports a namespace object (`FitAddon.FitAddon`, ...).
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Colours for [TerminalOptions.theme].
extension type TerminalTheme._(JSObject _) implements JSObject {
  /// Creates a theme object literal.
  external factory TerminalTheme({
    String background,
    String foreground,
    String cursor,
    String selectionBackground,
  });
}

/// Options for [Terminal].
extension type TerminalOptions._(JSObject _) implements JSObject {
  /// Creates an options object literal.
  external factory TerminalOptions({
    bool cursorBlink,
    int fontSize,
    String fontFamily,
    int scrollback,
    bool allowProposedApi,
    TerminalTheme theme,
  });
}

/// `{cols, rows}` passed to `onResize` listeners.
extension type ResizeEvent._(JSObject _) implements JSObject {
  external int get cols;
  external int get rows;
}

/// `terminal.buffer.active`.
extension type TerminalBuffer._(JSObject _) implements JSObject {
  /// `'normal'` or `'alternate'`.
  external String get type;

  /// First visible line.
  external int get viewportY;

  /// Line of the bottom of the scrollback.
  external int get baseY;
}

/// `terminal.modes`.
extension type TerminalModes._(JSObject _) implements JSObject {
  external bool get applicationCursorKeysMode;
  external bool get bracketedPasteMode;
}

/// Mutable option view returned by `terminal.options`.
extension type TerminalOptionsView._(JSObject _) implements JSObject {
  external set fontSize(int value);
  external int get fontSize;
}

/// `terminal.buffer`.
extension type TerminalBufferNamespace._(JSObject _) implements JSObject {
  external TerminalBuffer get active;
  external JSObject onBufferChange(JSFunction listener);
}

/// `terminal.unicode`.
extension type TerminalUnicode._(JSObject _) implements JSObject {
  external set activeVersion(String version);
}

/// The xterm.js `Terminal` class.
@JS('Terminal')
extension type Terminal._(JSObject _) implements JSObject {
  external factory Terminal(TerminalOptions options);

  external void open(web.HTMLElement parent);
  external void write(JSAny data, [JSFunction? callback]);
  external void loadAddon(JSObject addon);
  external void focus();
  external void resize(int cols, int rows);
  external void reset();
  external void clear();
  external int get cols;
  external int get rows;
  external TerminalBufferNamespace get buffer;
  external TerminalUnicode get unicode;
  external TerminalModes get modes;
  external TerminalOptionsView get options;
  external JSObject onData(JSFunction listener);
  external JSObject onBinary(JSFunction listener);
  external JSObject onResize(JSFunction listener);
  external JSObject onScroll(JSFunction listener);
  external JSObject onSelectionChange(JSFunction listener);
  external void scrollPages(int pages);
  external void scrollToBottom();
  external bool hasSelection();
  external String getSelection();
  external void clearSelection();
  external web.HTMLElement? get textarea;
}

/// `@xterm/addon-fit`.
@JS('FitAddon.FitAddon')
extension type FitAddon._(JSObject _) implements JSObject {
  external factory FitAddon();
  external void fit();
}

/// `@xterm/addon-web-links`.
@JS('WebLinksAddon.WebLinksAddon')
extension type WebLinksAddon._(JSObject _) implements JSObject {
  external factory WebLinksAddon();
}

/// `@xterm/addon-search`.
@JS('SearchAddon.SearchAddon')
extension type SearchAddon._(JSObject _) implements JSObject {
  external factory SearchAddon();
  external bool findNext(String term);
  external bool findPrevious(String term);
}

/// `@xterm/addon-unicode11`.
@JS('Unicode11Addon.Unicode11Addon')
extension type Unicode11Addon._(JSObject _) implements JSObject {
  external factory Unicode11Addon();
}
