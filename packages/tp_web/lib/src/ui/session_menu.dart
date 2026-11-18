import 'dart:js_interop';

import 'package:tp_protocol/tp_protocol.dart';
import 'package:web/web.dart' as web;

import '../conn/connection.dart';
import '../i18n/strings.dart';
import 'dom.dart';

/// Session picker in the top bar (docs/03 "[coolify ▾] [+ ny]"): lists the
/// agent's sessions, switches, creates, renames and ends them.
final class SessionMenu {
  SessionMenu(this.connection, {required this.strings}) {
    element = el('div', className: 'session-menu');
    _button = el('button', className: 'session-button', text: '…');
    _button.setAttribute('aria-haspopup', 'true');
    _button.onclick = ((web.Event _) => toggle()).toJS;
    _panel = el('div', className: 'session-panel hidden');
    _panel.setAttribute('role', 'menu');
    element
      ..appendChild(_button)
      ..appendChild(_panel);
    connection.sessionList.listen((_) => _render());
    connection.states.listen((state) {
      if (state is Live) _button.textContent = '${state.name} ▾';
    });
    web.document.addEventListener(
      'pointerdown',
      ((web.Event e) {
        final target = e.target;
        if (target != null &&
            target.isA<web.Node>() &&
            !element.contains(target as web.Node)) {
          close();
        }
      }).toJS,
    );
  }

  final Connection connection;
  final Strings strings;
  late final web.HTMLElement element;
  late final web.HTMLElement _button;
  late final web.HTMLElement _panel;

  void toggle() {
    if (_panel.classList.contains('hidden')) {
      connection.refreshSessions();
      _render();
      _panel.classList.remove('hidden');
    } else {
      close();
    }
  }

  void close() => _panel.classList.add('hidden');

  void _render() {
    _panel.textContent = '';
    final current = connection.currentSession;
    for (final s in connection.sessions) {
      final row = el(
        'div',
        className: 'session-row${s.id == current ? ' current' : ''}',
      );
      final pick = el('button', className: 'session-pick', text: s.name);
      pick.setAttribute('role', 'menuitem');
      final meta = s.exited != null
          ? strings['sessions.exited']
          : '${s.clients} ${strings['sessions.clients']}';
      pick.appendChild(el('span', className: 'muted', text: '  $meta'));
      pick.onclick = ((web.Event _) {
        close();
        connection.switchTo(s.id);
      }).toJS;
      final rename = el(
        'button',
        className: 'icon-btn',
        text: '✎',
        label: '${strings['sessions.rename']} ${s.name}',
      );
      rename.onclick = ((web.Event _) {
        final name = web.window.prompt(strings['sessions.newName'], s.name);
        if (name != null && name.trim().isNotEmpty) {
          connection.renameSession(
            s.id,
            name.trim().substring(
              0,
              name.trim().length.clamp(0, Limits.maxSessionNameLength),
            ),
          );
        }
      }).toJS;
      final kill = el(
        'button',
        className: 'icon-btn',
        text: '×',
        label: '${strings['sessions.end']} ${s.name}',
      );
      kill.onclick = ((web.Event _) {
        if (web.window.confirm(
          '${strings['sessions.confirmEnd']} «${s.name}»?',
        )) {
          connection.killSession(s.id);
        }
      }).toJS;
      row
        ..appendChild(pick)
        ..appendChild(rename)
        ..appendChild(kill);
      _panel.appendChild(row);
    }
    final add = el(
      'button',
      className: 'primary session-new',
      text: '+ ${strings['newSession']}',
    );
    add.onclick = ((web.Event _) {
      final name = web.window.prompt(strings['sessions.newName'], '');
      if (name == null) return;
      close();
      connection.newSession(name: name.trim().isEmpty ? null : name.trim());
    }).toJS;
    _panel.appendChild(add);
  }
}
