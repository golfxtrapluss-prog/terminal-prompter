import 'dart:async';
import 'dart:js_interop';

import 'package:tp_protocol/tp_protocol.dart';
import 'package:web/web.dart' as web;

import 'dom.dart';

/// What the key bar emits. The app decides what each means in the current
/// mode (docs/16 "Hva en tast gjør").
abstract interface class KeyBarListener {
  void onKey(TerminalKey key, Modifier modifier);
  void onChar(String char, Modifier modifier);
  void onCustom(CustomItem item);
}

/// The key bar (docs/16): rows of buttons that never steal focus from the
/// input field, sticky/lockable Ctrl and Alt, long press for alternates,
/// key repeat for arrows/Backspace/Delete, haptic tick on Android.
final class KeyBar {
  KeyBar(this.listener, {required this.rows, required this.newlineLabel}) {
    element = el('div', className: 'keybar');
    _rowsHost = el('div', className: 'keybar-rows');
    _dots = el('div', className: 'keybar-dots');
    element
      ..appendChild(_rowsHost)
      ..appendChild(_dots);
    // Never let a tap move focus away from the input (docs/16: the single
    // most important requirement for the bar).
    element.addEventListener(
      'pointerdown',
      ((web.PointerEvent e) => e.preventDefault()).toJS,
    );
    element.addEventListener(
      'mousedown',
      ((web.MouseEvent e) => e.preventDefault()).toJS,
    );
    _rowsHost.addEventListener('scroll', ((web.Event _) => _onScroll()).toJS);
    rebuild();
  }

  static const Duration _longPress = Duration(milliseconds: 450);
  static const Duration _repeatDelay = Duration(milliseconds: 400);
  static const Duration _repeatInterval = Duration(milliseconds: 50);

  final KeyBarListener listener;

  /// Rows to show (already filtered by settings).
  List<List<KeyBarItem>> rows;

  /// Label of the extra "new line" button shown in Prompter mode on phones.
  final String newlineLabel;

  /// Called when the newline button is tapped.
  void Function()? onNewline;

  late final web.HTMLElement element;
  late final web.HTMLElement _rowsHost;
  late final web.HTMLElement _dots;
  final ModifierState modifiers = ModifierState();
  final List<web.HTMLElement> _modifierButtons = [];
  final List<web.HTMLElement> _rowElements = [];
  final List<web.HTMLElement> _dotElements = [];
  int _row = 0;
  bool showNewline = false;

  /// Rebuilds the DOM from [rows].
  void rebuild() {
    _rowsHost.textContent = '';
    _dots.textContent = '';
    _rowElements.clear();
    _dotElements.clear();
    _modifierButtons.clear();
    for (var i = 0; i < rows.length; i++) {
      final row = el('div', className: 'keybar-row');
      for (final item in rows[i]) {
        row.appendChild(_button(item));
      }
      if (i == 0 && showNewline) {
        final nl = el(
          'button',
          className: 'key key-newline',
          text: newlineLabel,
        );
        _press(nl, onTap: () => onNewline?.call());
        row.appendChild(nl);
      }
      _rowsHost.appendChild(row);
      _rowElements.add(row);
      final dot = el('span', className: 'keybar-dot');
      final index = i;
      _press(dot, onTap: () => showRow(index));
      _dots.appendChild(dot);
      _dotElements.add(dot);
    }
    if (_row >= rows.length) _row = 0;
    // Jump (no animation) back to the row that was showing.
    _rowsHost.scrollLeft = _rowsHost.clientWidth * _row;
    _updateDots();
    _refreshModifiers();
  }

  /// Shows or hides the extra newline button; rebuilds only on change.
  void setShowNewline(bool value) {
    if (value == showNewline) return;
    showNewline = value;
    rebuild();
  }

  /// Replaces the rows and rebuilds.
  void setRows(List<List<KeyBarItem>> value) {
    rows = value;
    rebuild();
  }

  /// One-shot or locked modifier to apply to a key typed on the device's own
  /// keyboard (docs/16). Returns [Modifier.none] when nothing is armed.
  Modifier consumeForExternalKey() {
    final m = modifiers.consume();
    _refreshModifiers();
    return m;
  }

  /// True while Ctrl or Alt is armed or locked.
  bool get modifierArmed => modifiers.modifier != Modifier.none;

  /// Scrolls to [index].
  void showRow(int index) {
    if (index < 0 || index >= _rowElements.length) return;
    _row = index;
    _rowsHost.scrollTo(
      web.ScrollToOptions(
        left: _rowsHost.clientWidth * index,
        behavior: 'smooth',
      ),
    );
    _updateDots();
  }

  void _onScroll() {
    final width = _rowsHost.clientWidth;
    if (width == 0) return;
    final index = (_rowsHost.scrollLeft / width).round();
    if (index != _row && index < _rowElements.length) {
      _row = index;
      _updateDots();
    }
  }

  void _updateDots() {
    for (var i = 0; i < _dotElements.length; i++) {
      _dotElements[i].className = i == _row
          ? 'keybar-dot active'
          : 'keybar-dot';
    }
  }

  void _refreshModifiers() {
    for (final b in _modifierButtons) {
      final m = b.dataset['modifier'] == 'alt' ? Modifier.alt : Modifier.ctrl;
      final active = modifiers.modifier == m;
      b.className =
          'key key-mod${active ? (modifiers.locked ? ' locked' : ' armed') : ''}';
    }
  }

  web.HTMLElement _button(KeyBarItem item) {
    switch (item) {
      case CharItem(:final char, :final longPress):
        final b = el(
          'button',
          className: 'key',
          text: char,
          title: longPress == null ? null : 'hold: $longPress',
          label: char,
        );
        _press(
          b,
          onTap: () => listener.onChar(char, modifiers.consume()),
          onLongPress: longPress == null
              ? null
              : () => listener.onChar(longPress, modifiers.consume()),
        );
        return b;
      case KeyItem(:final key):
        final b = el(
          'button',
          className: 'key key-${key.name}',
          text: key.label,
        );
        final repeats = const {
          TerminalKey.arrowUp,
          TerminalKey.arrowDown,
          TerminalKey.arrowLeft,
          TerminalKey.arrowRight,
          TerminalKey.backspace,
          TerminalKey.delete,
        }.contains(key);
        _press(
          b,
          onTap: () => listener.onKey(key, modifiers.consume()),
          repeat: repeats
              ? () => listener.onKey(key, modifiers.modifier)
              : null,
        );
        return b;
      case ModifierItem(:final modifier):
        final b = el(
          'button',
          className: 'key key-mod',
          text: modifier == Modifier.alt ? 'Alt' : 'Ctrl',
        );
        b.dataset['modifier'] = modifier.name;
        _modifierButtons.add(b);
        _press(
          b,
          onTap: () {
            modifiers.tap(modifier);
            _refreshModifiers();
          },
        );
        return b;
      case CustomItem():
        final b = el(
          'button',
          className: 'key key-custom',
          text: item.label,
          title: item.send,
          label: item.label,
        );
        _press(b, onTap: () => listener.onCustom(item));
        return b;
    }
  }

  /// Called after a key was consumed so a one-shot modifier is cleared
  /// visually.
  void keyConsumed() => _refreshModifiers();

  /// Pointer handling: tap, optional long press, optional auto-repeat.
  void _press(
    web.HTMLElement button, {
    required void Function() onTap,
    void Function()? onLongPress,
    void Function()? repeat,
  }) {
    Timer? longTimer;
    Timer? repeatTimer;
    var fired = false;

    void end() {
      longTimer?.cancel();
      repeatTimer?.cancel();
      longTimer = null;
      repeatTimer = null;
      button.classList.remove('pressed');
    }

    button.addEventListener(
      'pointerdown',
      ((web.PointerEvent e) {
        e.preventDefault();
        button.classList.add('pressed');
        fired = false;
        _vibrate();
        if (onLongPress != null) {
          longTimer = Timer(_longPress, () {
            fired = true;
            onLongPress();
            _refreshModifiers();
          });
        }
        if (repeat != null) {
          longTimer = Timer(_repeatDelay, () {
            fired = true;
            onTap();
            _refreshModifiers();
            repeatTimer = Timer.periodic(_repeatInterval, (_) => repeat());
          });
        }
      }).toJS,
    );
    button.addEventListener(
      'pointerup',
      ((web.PointerEvent e) {
        e.preventDefault();
        final wasFired = fired;
        end();
        if (!wasFired) {
          onTap();
          _refreshModifiers();
        }
      }).toJS,
    );
    button.addEventListener(
      'pointercancel',
      ((web.PointerEvent _) => end()).toJS,
    );
    button.addEventListener(
      'pointerleave',
      ((web.PointerEvent _) => end()).toJS,
    );
    button.addEventListener(
      'contextmenu',
      ((web.Event e) => e.preventDefault()).toJS,
    );
  }

  static void _vibrate() {
    try {
      web.window.navigator.vibrate(10.toJS);
    } on Object {
      // Not supported (iOS, desktop); purely cosmetic.
    }
  }
}
