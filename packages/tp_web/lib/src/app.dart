import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:tp_protocol/tp_protocol.dart';
import 'package:web/web.dart' as web;

import 'client_info.dart';
import 'conn/connection.dart';
import 'conn/ws_transport.dart';
import 'i18n/strings.dart';
import 'pwa/pwa.dart';
import 'settings.dart';
import 'storage.dart';
import 'ui/dom.dart';
import 'ui/keybar.dart';
import 'ui/prompter.dart';
import 'ui/settings_panel.dart';
import 'ui/terminal_view.dart';
import 'ui/topbar.dart';
import 'ui/viewport.dart';

/// Builds the page and wires terminal, Prompter, key bar and connection
/// together (docs/03, docs/16). Mobile-first: on touch devices Prompter mode
/// and the key bar are on by default.
final class App implements KeyBarListener {
  /// Mounts the app into [root].
  App(web.HTMLElement root) : _root = root;

  final web.HTMLElement _root;
  final BrowserStorage _store = const BrowserStorage();

  late final Settings _settings;
  late final Strings _strings;
  late final bool _touch;
  late final TerminalView _terminal;
  late final Connection _connection;
  late final PrompterView _prompter;
  late final KeyBar _keyBar;
  late final SettingsPanel _settingsPanel;
  late final web.HTMLElement _hint;
  late final web.HTMLElement _modeButton;
  InputMode _mode = InputMode.prompter;
  bool _autoRaw = false;

  /// Starts the app.
  void run() {
    web.document.title = 'Terminal Prompter';
    _settings = Settings.load(_store);
    _strings = Strings.forLanguage(
      _settings.language.isEmpty
          ? web.window.navigator.language
          : _settings.language,
    );
    _touch = web.window.matchMedia('(pointer: coarse)').matches;

    final terminalHost = el('main', className: 'terminal');
    _terminal = TerminalView(
      terminalHost,
      strings: _strings,
      fontSize: _settings.fontSize,
    );
    _connection = Connection(
      terminal: _terminal,
      wsUrl: _wsUrl(),
      transportFactory: WsClientTransport.new,
      clientId: clientIdentifier(),
      store: _store,
    );
    _prompter = PrompterView(
      strings: _strings,
      settings: _settings,
      store: _store,
      connection: _connection,
      touch: _touch,
      bracketedPaste: () => _terminal.bracketedPaste,
      onModeToggle: toggleMode,
      onScrollTerminal: _terminal.scrollPages,
    )..onModifiedChar = _onPrompterModifiedChar;
    _keyBar = KeyBar(
      this,
      rows: _keyBarRows(),
      newlineLabel: _strings['newline'],
    )..onNewline = () => _prompter.insertText('\n');
    _settingsPanel = SettingsPanel(
      strings: _strings,
      settings: _settings,
      onSave: _applySettings,
      onClearHistory: _prompter.history.clear,
    );
    final topbar = TopBar(
      _connection,
      strings: _strings,
      onSettings: _settingsPanel.toggle,
    );

    final bottom = el('div', className: 'bottom');
    final toolbar = el('div', className: 'toolbar');
    _modeButton = el('button', className: 'mode');
    _modeButton.addEventListener(
      'pointerdown',
      ((web.Event e) => e.preventDefault()).toJS,
    );
    _modeButton.onclick = ((web.Event _) => toggleMode()).toJS;
    final snippetsButton = el('button', text: '📎 ${_strings['snippets']}');
    snippetsButton.addEventListener(
      'pointerdown',
      ((web.Event e) => e.preventDefault()).toJS,
    );
    snippetsButton.onclick = ((web.Event _) => _prompter.toggleSnippets()).toJS;
    final keybarButton = el(
      'button',
      text: '⌨ ${_strings['keybar']}',
      title: 'Ctrl+Shift+K',
      label: _strings['keybar'],
    );
    keybarButton.addEventListener(
      'pointerdown',
      ((web.Event e) => e.preventDefault()).toJS,
    );
    keybarButton.onclick = ((web.Event _) => _toggleKeyBar()).toJS;
    _hint = el('span', className: 'hint');
    toolbar
      ..appendChild(_modeButton)
      ..appendChild(snippetsButton)
      ..appendChild(keybarButton)
      ..appendChild(_hint);
    bottom
      ..appendChild(toolbar)
      ..appendChild(_prompter.element)
      ..appendChild(_keyBar.element);

    _root
      ..appendChild(topbar.element)
      ..appendChild(terminalHost)
      ..appendChild(bottom)
      ..appendChild(_settingsPanel.element);

    ViewportManager(_root).onChange = _terminal.fit;
    _applyKeyBarVisibility(_settings.keyBarVisibleFor(touch: _touch));
    _applyKeyBarScale();

    _terminal
      ..onInput = _onTerminalInput
      ..onResize = _connection.sendResize
      ..onAlternateScreen = _onAlternateScreen
      ..onFontSizeChanged = (size) {
        _settings.fontSize = size;
        _settings.save(_store);
      }
      ..bind();
    _terminal.fit();

    _setMode(_settings.modeFor(touch: _touch));
    _connection.states.listen((state) {
      if (state is Live) _focusInput();
    });
    web.window.addEventListener(
      'online',
      ((web.Event _) => _connection.notifyOnline()).toJS,
    );
    web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) {
        if (web.document.visibilityState == 'visible') {
          _connection.notifyVisible();
        }
      }).toJS,
    );
    web.document.addEventListener(
      'keydown',
      ((web.KeyboardEvent e) {
        if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.code == 'Space') {
          e.preventDefault();
          toggleMode();
        } else if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.code == 'KeyK') {
          e.preventDefault();
          _toggleKeyBar();
        }
      }).toJS,
    );

    registerServiceWorker();
    _connection.start();
  }

  // ---- mode ----

  /// Switches between Prompter and Raw mode.
  void toggleMode() {
    _autoRaw = false;
    _setMode(_mode == InputMode.prompter ? InputMode.raw : InputMode.prompter);
  }

  void _setMode(InputMode mode) {
    _mode = mode;
    final prompter = mode == InputMode.prompter;
    _root.classList.toggle('mode-prompter', prompter);
    _root.classList.toggle('mode-raw', !prompter);
    _modeButton.textContent = prompter
        ? '● ${_strings['mode.prompter']}'
        : '● ${_strings['mode.raw']}';
    _keyBar.setShowNewline(prompter && _prompter.enterSends);
    _hint.textContent = !prompter
        ? _strings['hint.raw']
        : _touch
        ? _strings['hint.mobile']
        : _prompter.enterSends
        ? _strings['hint.desktopEnterSends']
        : _strings['hint.desktop'];
    _focusInput();
    Timer(const Duration(milliseconds: 50), _terminal.fit);
  }

  void _onAlternateScreen(bool alternate) {
    // Full-screen programs need every keystroke: switch to Raw and back.
    if (alternate && _mode == InputMode.prompter) {
      _autoRaw = true;
      _setMode(InputMode.raw);
    } else if (!alternate && _autoRaw) {
      _autoRaw = false;
      _setMode(InputMode.prompter);
    }
  }

  void _focusInput() {
    if (_mode == InputMode.prompter) {
      _prompter.focus();
    } else {
      _terminal.focus();
    }
  }

  // ---- key bar ----

  List<List<KeyBarItem>> _keyBarRows() => [
    KeyBarRows.basic,
    KeyBarRows.symbols,
    if (!_settings.hideKeyRow) KeyBarRows.keys,
    if (_settings.customButtons.isNotEmpty) _settings.customButtons,
  ];

  void _toggleKeyBar() =>
      _applyKeyBarVisibility(_keyBar.element.classList.contains('hidden'));

  void _applyKeyBarVisibility(bool visible) {
    _keyBar.element.classList.toggle('hidden', !visible);
    Timer(const Duration(milliseconds: 50), _terminal.fit);
  }

  void _applyKeyBarScale() {
    _root.style.setProperty('--key-scale', '${_settings.keyBarScale / 100}');
  }

  /// Raw-mode keyboard input from xterm. A Ctrl/Alt armed on the key bar
  /// applies to the next single character typed on the device keyboard.
  void _onTerminalInput(Uint8List data) {
    if (_keyBar.modifierArmed &&
        data.length == 1 &&
        data[0] >= 0x20 &&
        data[0] < 0x7f) {
      final modifier = _keyBar.consumeForExternalKey();
      _sendRaw(KeyEncoder.encodeChar(String.fromCharCode(data[0]), modifier));
      return;
    }
    _connection.sendInput(data);
  }

  /// Prompter-mode character from the device keyboard while a modifier is
  /// armed. Returns true when it was consumed.
  bool _onPrompterModifiedChar(String char) {
    if (!_keyBar.modifierArmed) return false;
    final modifier = _keyBar.consumeForExternalKey();
    if (modifier == Modifier.ctrl) {
      _prompter.handleCtrl(char);
    }
    return true;
  }

  void _sendRaw(String sequence) =>
      _connection.sendInput(Connection.encodeInput(sequence));

  @override
  void onChar(String char, Modifier modifier) {
    if (_mode == InputMode.raw) {
      _sendRaw(KeyEncoder.encodeChar(char, modifier));
      return;
    }
    switch (modifier) {
      case Modifier.none:
        _prompter.insertText(char);
      case Modifier.ctrl:
        _prompter.handleCtrl(char);
      case Modifier.alt:
        break; // No Alt bindings in the field.
    }
    _keyBar.keyConsumed();
  }

  @override
  void onKey(TerminalKey key, Modifier modifier) {
    if (_mode == InputMode.raw) {
      final seq = KeyEncoder.encodeKey(
        key,
        applicationCursor: _terminal.applicationCursor,
      );
      _sendRaw(modifier == Modifier.alt ? '$esc$seq' : seq);
      return;
    }
    switch (key) {
      case TerminalKey.arrowLeft:
        _prompter.moveCaret(-1);
      case TerminalKey.arrowRight:
        _prompter.moveCaret(1);
      case TerminalKey.arrowUp:
        _prompter.historyPrevious();
      case TerminalKey.arrowDown:
        _prompter.historyNext();
      case TerminalKey.tab:
        _prompter.tabComplete();
      case TerminalKey.escape:
        _prompter.clearField();
      case TerminalKey.enter:
        _prompter.submit();
      case TerminalKey.backspace:
        _prompter.deleteLeft();
      case TerminalKey.delete:
        _prompter.deleteRight();
      case TerminalKey.home:
        _prompter.caretHome();
      case TerminalKey.end:
        _prompter.caretEnd();
      case TerminalKey.pageUp:
        _terminal.scrollPages(-1);
      case TerminalKey.pageDown:
        _terminal.scrollPages(1);
      case TerminalKey.insert:
      case TerminalKey.f1:
      case TerminalKey.f2:
      case TerminalKey.f3:
      case TerminalKey.f4:
      case TerminalKey.f5:
      case TerminalKey.f6:
      case TerminalKey.f7:
      case TerminalKey.f8:
      case TerminalKey.f9:
      case TerminalKey.f10:
      case TerminalKey.f11:
      case TerminalKey.f12:
        // Only meaningful for full-screen programs, which run in Raw mode.
        _sendRaw(
          KeyEncoder.encodeKey(
            key,
            applicationCursor: _terminal.applicationCursor,
          ),
        );
    }
    _keyBar.keyConsumed();
  }

  @override
  void onCustom(CustomItem item) {
    if (_mode == InputMode.raw) {
      _sendRaw(item.run ? '${item.send}\r' : item.send);
      return;
    }
    if (item.run) {
      _prompter.run(item.send);
    } else {
      _prompter.insertText(item.send);
    }
  }

  // ---- settings ----

  void _applySettings({required bool reload}) {
    _settings.save(_store);
    if (reload) {
      web.window.location.reload();
      return;
    }
    _terminal.fontSize = _settings.fontSize;
    _prompter.reloadSettings();
    _keyBar.setRows(_keyBarRows());
    _applyKeyBarScale();
    _applyKeyBarVisibility(_settings.keyBarVisibleFor(touch: _touch));
    _setMode(_mode);
  }

  /// `ws(s)://host/<base path>api/ws`, derived from the page URL so a
  /// configured `base_path` is honoured.
  static String _wsUrl() {
    final location = web.window.location;
    final scheme = location.protocol == 'https:' ? 'wss' : 'ws';
    final path = location.pathname;
    final base = path.endsWith('/')
        ? path
        : path.substring(0, path.lastIndexOf('/') + 1);
    return '$scheme://${location.host}${base}api/ws';
  }
}
