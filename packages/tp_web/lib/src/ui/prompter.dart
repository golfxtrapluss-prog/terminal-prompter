import 'dart:js_interop';

import 'package:tp_protocol/tp_protocol.dart';
import 'package:web/web.dart' as web;

import '../conn/connection.dart';
import '../conn/transport.dart';
import '../i18n/strings.dart';
import '../model/danger.dart';
import '../model/history.dart';
import '../model/prompter_encoding.dart';
import '../model/queue.dart';
import '../model/snippets.dart';
import '../settings.dart';
import 'dom.dart';

/// The Prompter field (docs/03): compose locally, send as one unit, history
/// with search, snippets, dangerous-command confirmation, offline queue with
/// delivery status.
final class PrompterView {
  PrompterView({
    required this.strings,
    required this.settings,
    required KeyValueStore store,
    required this.connection,
    required this.touch,
    required this.bracketedPaste,
    required this.onModeToggle,
    required this.onScrollTerminal,
  }) : history = CommandHistory(store),
       snippets = SnippetLibrary(store),
       queue = CommandQueue(store: store),
       _danger = DangerDetector(settings.dangerPatterns) {
    element = el('div', className: 'prompter');
    _status = el('div', className: 'prompter-status');
    _confirm = el('div', className: 'prompter-confirm hidden');
    _search = el('div', className: 'prompter-search hidden');
    _snippetPanel = el('div', className: 'prompter-snippets hidden');
    _field =
        el('textarea', className: 'prompter-field') as web.HTMLTextAreaElement;
    _field
      ..rows = 1
      ..placeholder = r'$'
      ..spellcheck = false
      ..autocomplete = 'off'
      ..autocapitalize = 'off'
      ..setAttribute('autocorrect', settings.autocorrect ? 'on' : 'off')
      ..setAttribute('enterkeyhint', 'send');
    final row = el('div', className: 'prompter-row');
    _sendButton =
        el('button', className: 'send', text: strings['send'])
            as web.HTMLButtonElement;
    _sendButton.addEventListener(
      'pointerdown',
      ((web.Event e) => e.preventDefault()).toJS,
    );
    _sendButton.onclick = ((web.Event _) => submit()).toJS;
    row
      ..appendChild(_field)
      ..appendChild(_sendButton);
    element
      ..appendChild(_status)
      ..appendChild(_confirm)
      ..appendChild(_search)
      ..appendChild(_snippetPanel)
      ..appendChild(row);
    _field.addEventListener('keydown', _onKeyDown.toJS);
    _field.addEventListener('input', ((web.Event _) => _autoGrow()).toJS);
    // Phone keyboards deliver characters as beforeinput, often without a
    // usable keydown, so the armed key bar modifier is applied here.
    _field.addEventListener(
      'beforeinput',
      ((web.InputEvent e) {
        final data = e.data;
        if (e.inputType == 'insertText' && data != null && data.length == 1) {
          if (onModifiedChar?.call(data) ?? false) e.preventDefault();
        }
      }).toJS,
    );
    connection.acks.listen((id) {
      if (queue.ack(id)) _renderStatus();
    });
    connection.states.listen((state) {
      if (state is Live) _flushQueue();
    });
    _renderStatus();
  }

  final Strings strings;
  final Settings settings;
  final Connection connection;
  final bool touch;

  /// Whether the shell currently has bracketed paste enabled.
  final bool Function() bracketedPaste;
  final void Function() onModeToggle;
  final void Function(int pages) onScrollTerminal;

  /// Called for a single typed character before it reaches the field; return
  /// true to swallow it (used for Ctrl/Alt armed on the key bar).
  bool Function(String char)? onModifiedChar;
  final CommandHistory history;
  final SnippetLibrary snippets;
  final CommandQueue queue;
  DangerDetector _danger;

  late final web.HTMLElement element;
  late final web.HTMLElement _status;
  late final web.HTMLElement _confirm;
  late final web.HTMLElement _search;
  late final web.HTMLElement _snippetPanel;
  late final web.HTMLTextAreaElement _field;
  late final web.HTMLButtonElement _sendButton;

  bool get enterSends => settings.enterSendsFor(touch: touch);

  /// Current field text.
  String get text => _field.value;
  set text(String value) {
    _field.value = value;
    _autoGrow();
  }

  void focus() => _field.focus();

  /// Re-reads the dangerous patterns after a settings change.
  void reloadSettings() {
    _danger = DangerDetector(settings.dangerPatterns);
    _field.setAttribute('autocorrect', settings.autocorrect ? 'on' : 'off');
  }

  // ---- editing helpers used by the key bar ----

  void insertText(String s) {
    final start = _field.selectionStart;
    final end = _field.selectionEnd;
    final v = _field.value;
    _field.value = v.substring(0, start) + s + v.substring(end);
    _field.selectionStart = _field.selectionEnd = start + s.length;
    _autoGrow();
    _field.focus();
  }

  void moveCaret(int delta) {
    final pos = (_field.selectionEnd + delta).clamp(0, _field.value.length);
    _field.selectionStart = _field.selectionEnd = pos;
    _field.focus();
  }

  void caretHome() {
    _field.selectionStart = _field.selectionEnd = 0;
    _field.focus();
  }

  void caretEnd() {
    _field.selectionStart = _field.selectionEnd = _field.value.length;
    _field.focus();
  }

  void deleteRight() {
    final start = _field.selectionStart;
    final end = _field.selectionEnd;
    final v = _field.value;
    if (start != end) {
      _field.value = v.substring(0, start) + v.substring(end);
    } else if (start < v.length) {
      _field.value = v.substring(0, start) + v.substring(start + 1);
    }
    _field.selectionStart = _field.selectionEnd = start;
    _autoGrow();
  }

  void deleteLeft() {
    final start = _field.selectionStart;
    final end = _field.selectionEnd;
    final v = _field.value;
    if (start != end) {
      _field.value = v.substring(0, start) + v.substring(end);
      _field.selectionStart = _field.selectionEnd = start;
    } else if (start > 0) {
      _field.value = v.substring(0, start - 1) + v.substring(start);
      _field.selectionStart = _field.selectionEnd = start - 1;
    }
    _autoGrow();
  }

  void clearField() {
    text = '';
    _hide(_confirm);
    _hide(_search);
  }

  void historyPrevious() {
    final v = history.previous(text);
    if (v != null) {
      text = v;
      caretEnd();
    }
  }

  void historyNext() {
    final v = history.next();
    if (v != null) {
      text = v;
      caretEnd();
    }
  }

  /// Tab: let the shell complete. Sends the field plus `\t` and hands over
  /// to Raw mode so the user continues on the shell's own line.
  void tabComplete() {
    final current = text;
    if (current.isEmpty) return;
    connection.sendInput(Connection.encodeInput('$current\t'));
    text = '';
    onModeToggle();
  }

  /// Ctrl+letter in Prompter mode: C/D/Z/L go to the PTY, the rest edit.
  bool handleCtrl(String letter) {
    switch (letter.toLowerCase()) {
      case 'c':
        connection.sendSignal(TerminalSignal.interrupt);
      case 'd':
        if (text.isEmpty) connection.sendSignal(TerminalSignal.eof);
      case 'z':
        connection.sendSignal(TerminalSignal.suspend);
      case 'l':
        connection.sendInput(Connection.encodeInput('\x0c'));
      case 'a':
        caretHome();
      case 'e':
        caretEnd();
      case 'u':
        clearField();
      case 'w':
        _deleteWord();
      case 'r':
        toggleSearch();
      default:
        return false;
    }
    return true;
  }

  // ---- sending ----

  /// Sends the field as a command (after a danger check).
  void submit() {
    final command = text;
    if (command.trim().isEmpty) return;
    final pattern = _danger.match(command);
    if (pattern != null) {
      _showConfirm(
        strings['danger.title'],
        detail: command,
        danger: true,
        actions: {
          strings['danger.run']: () => _send(command),
          strings['cancel']: () {},
        },
      );
      return;
    }
    _send(command);
  }

  /// Runs [command] from a custom button or snippet.
  void run(String command) {
    text = command;
    submit();
  }

  void _send(String command) {
    history.add(command);
    text = '';
    final bytes = PrompterEncoding.encodeCommand(
      command,
      bracketedPaste: bracketedPaste(),
    );
    final pending = queue.enqueue(command, bytes);
    _dispatch(pending);
    _renderStatus();
    _field.focus();
  }

  void _dispatch(PendingCommand cmd) {
    if (!connection.isLive) return;
    final id = connection.sendInput(cmd.bytes, fromPrompter: true);
    if (id == null) return;
    queue.markSent(cmd, id);
  }

  void _flushQueue() {
    for (final cmd in queue.takeSendable()) {
      _dispatch(cmd);
    }
    _renderStatus();
    final stale = queue.items
        .where((c) => c.status == DeliveryStatus.stale)
        .toList();
    if (stale.isNotEmpty) _askStale(stale.first);
  }

  void _askStale(PendingCommand cmd) {
    _showConfirm(
      strings['stale.title'],
      detail: cmd.text,
      actions: {
        strings['stale.send']: () {
          queue.confirm(cmd);
          _flushQueue();
        },
        strings['stale.drop']: () {
          queue.discard(cmd);
          _flushQueue();
        },
      },
    );
  }

  void _renderStatus() {
    _status.textContent = '';
    final recent = queue.items.reversed.take(4).toList().reversed;
    for (final cmd in recent) {
      final (icon, cls) = switch (cmd.status) {
        DeliveryStatus.queued => ('⏳', 'queued'),
        DeliveryStatus.sent => ('⏳', 'sent'),
        DeliveryStatus.acked => ('✓', 'acked'),
        DeliveryStatus.stale => ('⌛', 'stale'),
      };
      final chip = el(
        'span',
        className: 'chip $cls',
        title: cmd.status == DeliveryStatus.queued ? strings['queued'] : null,
      );
      chip
        ..appendChild(el('span', className: 'icon', text: icon))
        ..appendChild(el('span', text: cmd.text.split('\n').first));
      chip.addEventListener(
        'pointerdown',
        ((web.Event e) => e.preventDefault()).toJS,
      );
      chip.onclick = ((web.Event _) {
        if (cmd.status == DeliveryStatus.stale) {
          _askStale(cmd);
        } else {
          text = cmd.text;
          caretEnd();
        }
      }).toJS;
      _status.appendChild(chip);
    }
    _status.className =
        'prompter-status${queue.items.isEmpty ? ' hidden' : ''}';
  }

  // ---- confirm bar, search, snippets ----

  void _showConfirm(
    String title, {
    required String detail,
    required Map<String, void Function()> actions,
    bool danger = false,
  }) {
    _confirm.textContent = '';
    _confirm
      ..appendChild(el('div', className: 'confirm-title', text: title))
      ..appendChild(el('code', className: 'confirm-detail', text: detail));
    final buttons = el('div', className: 'confirm-actions');
    var first = true;
    for (final entry in actions.entries) {
      final b = el(
        'button',
        className: first ? (danger ? 'danger' : 'primary') : '',
        text: entry.key,
      );
      first = false;
      b.addEventListener(
        'pointerdown',
        ((web.Event e) => e.preventDefault()).toJS,
      );
      b.onclick = ((web.Event _) {
        _hide(_confirm);
        entry.value();
        _field.focus();
      }).toJS;
      buttons.appendChild(b);
    }
    _confirm.appendChild(buttons);
    _confirm.classList.remove('hidden');
  }

  /// Ctrl+R: incremental history search above the field.
  void toggleSearch() {
    if (!_search.classList.contains('hidden')) {
      _hide(_search);
      _field.focus();
      return;
    }
    _search.textContent = '';
    final input =
        el('input', className: 'search-input') as web.HTMLInputElement;
    input
      ..placeholder = strings['search.placeholder']
      ..autocomplete = 'off';
    final list = el('div', className: 'search-list');
    void refresh() {
      list.textContent = '';
      for (final item in history.search(input.value)) {
        final b = el('button', className: 'search-item', text: item);
        b.addEventListener(
          'pointerdown',
          ((web.Event e) => e.preventDefault()).toJS,
        );
        b.onclick = ((web.Event _) {
          text = item;
          _hide(_search);
          caretEnd();
        }).toJS;
        list.appendChild(b);
      }
    }

    input.addEventListener('input', ((web.Event _) => refresh()).toJS);
    input.addEventListener(
      'keydown',
      ((web.KeyboardEvent e) {
        if (e.key == 'Escape') {
          _hide(_search);
          _field.focus();
        } else if (e.key == 'Enter') {
          final first = history.search(input.value);
          if (first.isNotEmpty) text = first.first;
          _hide(_search);
          caretEnd();
          e.preventDefault();
        }
      }).toJS,
    );
    _search
      ..appendChild(input)
      ..appendChild(list);
    _search.classList.remove('hidden');
    refresh();
    input.focus();
  }

  /// Toggles the snippet panel.
  void toggleSnippets() {
    if (!_snippetPanel.classList.contains('hidden')) {
      _hide(_snippetPanel);
      _field.focus();
      return;
    }
    _renderSnippets();
    _snippetPanel.classList.remove('hidden');
  }

  void _renderSnippets() {
    _snippetPanel.textContent = '';
    final list = el('div', className: 'snippet-list');
    if (snippets.items.isEmpty) {
      list.appendChild(
        el('p', className: 'muted', text: strings['snippet.none']),
      );
    }
    for (final s in snippets.items) {
      final rowEl = el('div', className: 'snippet-row');
      final use = el(
        'button',
        className: 'snippet-use',
        text: s.name,
        title: s.command,
        label: s.name,
      );
      use.addEventListener(
        'pointerdown',
        ((web.Event e) => e.preventDefault()).toJS,
      );
      use.onclick = ((web.Event _) => _useSnippet(s)).toJS;
      final del = el(
        'button',
        className: 'snippet-del',
        text: '×',
        title: strings['delete'],
        label: '${strings['delete']} ${s.name}',
      );
      del.onclick = ((web.Event _) {
        snippets.remove(s.name);
        _renderSnippets();
      }).toJS;
      rowEl
        ..appendChild(use)
        ..appendChild(del);
      list.appendChild(rowEl);
    }
    final save = el('button', text: strings['snippet.save']);
    save.onclick = ((web.Event _) {
      if (text.trim().isEmpty) return;
      final name = web.window.prompt(
        strings['snippet.name'],
        text
            .split('\n')
            .first
            .substring(0, text.split('\n').first.length.clamp(0, 24)),
      );
      if (name == null || name.trim().isEmpty) return;
      snippets.save(Snippet(name: name.trim(), command: text));
      _renderSnippets();
    }).toJS;
    final exportArea =
        el('textarea', className: 'snippet-json') as web.HTMLTextAreaElement;
    exportArea
      ..rows = 4
      ..value = snippets.exportJson();
    final import = el('button', text: strings['snippet.apply']);
    import.onclick = ((web.Event _) {
      try {
        snippets.importJson(exportArea.value);
        _renderSnippets();
      } on FormatException catch (e) {
        web.window.alert('${strings['settings.invalidJson']}: ${e.message}');
      }
    }).toJS;
    _snippetPanel
      ..appendChild(list)
      ..appendChild(save)
      ..appendChild(
        el('div', className: 'muted', text: strings['snippet.export']),
      )
      ..appendChild(exportArea)
      ..appendChild(import);
  }

  void _useSnippet(Snippet s) {
    final values = <String, String>{};
    for (final v in s.variables) {
      final value = web.window.prompt('${strings['snippet.value']} $v');
      if (value == null) return;
      values[v] = value;
    }
    text = s.expand(values);
    _hide(_snippetPanel);
    caretEnd();
  }

  // ---- physical keyboard ----

  void _onKeyDown(web.KeyboardEvent e) {
    final ctrl = e.ctrlKey || e.metaKey;
    if (e.key == 'Enter') {
      final send = ctrl || (enterSends ? !e.shiftKey : false);
      if (send) {
        e.preventDefault();
        submit();
      }
      return;
    }
    if (e.key == 'Escape') {
      e.preventDefault();
      clearField();
      return;
    }
    if (e.key == 'ArrowUp' && !ctrl && _caretOnFirstLine()) {
      e.preventDefault();
      historyPrevious();
      return;
    }
    if (e.key == 'ArrowDown' && !ctrl && _caretOnLastLine()) {
      e.preventDefault();
      historyNext();
      return;
    }
    if (e.key == 'PageUp' || e.key == 'PageDown') {
      e.preventDefault();
      onScrollTerminal(e.key == 'PageUp' ? -1 : 1);
      return;
    }
    if (ctrl && e.shiftKey && e.code == 'Space') {
      e.preventDefault();
      onModeToggle();
      return;
    }
    if (ctrl && e.key.length == 1) {
      final letter = e.key.toLowerCase();
      // Ctrl+C with a selection stays a copy; Ctrl+V/X/A are the browser's.
      if (letter == 'c' && _field.selectionStart != _field.selectionEnd) return;
      if ('vxay'.contains(letter) && letter != 'a') return;
      if (handleCtrl(letter)) e.preventDefault();
    }
  }

  bool _caretOnFirstLine() =>
      !_field.value.substring(0, _field.selectionStart).contains('\n');
  bool _caretOnLastLine() =>
      !_field.value.substring(_field.selectionEnd).contains('\n');

  void _deleteWord() {
    final start = _field.selectionStart;
    final v = _field.value;
    var i = start;
    while (i > 0 && v[i - 1] == ' ') {
      i--;
    }
    while (i > 0 && v[i - 1] != ' ') {
      i--;
    }
    _field.value = v.substring(0, i) + v.substring(start);
    _field.selectionStart = _field.selectionEnd = i;
    _autoGrow();
  }

  void _autoGrow() {
    final lines = '\n'.allMatches(_field.value).length + 1;
    _field.rows = lines.clamp(1, 6);
  }

  static void _hide(web.HTMLElement e) => e.classList.add('hidden');
}
