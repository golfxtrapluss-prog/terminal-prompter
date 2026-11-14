import 'package:web/web.dart' as web;

import 'conn/connection.dart';
import 'ui/dom.dart';
import 'ui/terminal_view.dart';
import 'ui/topbar.dart';

/// Builds the page and starts the connection.
///
/// Milestone M2: Raw mode only, one session, no login. The Prompter field,
/// session tabs and login page follow in M4-M6.
final class App {
  /// Mounts the app into [root].
  App(web.HTMLElement root) : _root = root;

  final web.HTMLElement _root;

  /// Starts the app.
  void run() {
    web.document.title = 'Terminal Prompter';
    final terminalHost = el('main', className: 'terminal');
    final terminal = TerminalView(terminalHost);
    final connection = Connection(terminal: terminal, wsUrl: _wsUrl());
    final topbar = TopBar(connection);
    final footer = el(
      'footer',
      className: 'statusbar',
      text:
          'Raw mode: keys go straight to the shell. Prompter mode arrives in M4.',
    );

    _root
      ..appendChild(topbar.element)
      ..appendChild(terminalHost)
      ..appendChild(footer);

    terminal
      ..onInput = connection.sendInput
      ..onResize = connection.sendResize
      ..bind();
    terminal.fit();
    connection.states.listen((state) {
      if (state is Live) terminal.focus();
    });
    connection.start();
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
