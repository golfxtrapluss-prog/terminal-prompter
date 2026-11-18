import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../conn/connection.dart';
import '../i18n/strings.dart';
import 'dom.dart';
import 'session_menu.dart';

/// Top bar: connection dot, host, session name, RTT, transport, actions.
/// Compact enough for a phone in portrait (docs/16).
final class TopBar {
  /// Builds the bar and wires it to [connection].
  TopBar(
    this.connection, {
    required this.strings,
    required void Function() onSettings,
  }) {
    element = el('header', className: 'topbar');
    _dot = el('span', className: 'dot', title: 'disconnected');
    _host = el('span', className: 'host', text: connection.host);
    _rtt = el('span', className: 'rtt');
    _transport = el('span', className: 'transport', text: 'WS');
    final sessionMenu = SessionMenu(connection, strings: strings);
    final settings = el(
      'button',
      className: 'icon-btn',
      text: '⚙',
      title: strings['settings'],
      label: strings['settings'],
    );
    settings.onclick = ((web.Event _) => onSettings()).toJS;
    element
      ..appendChild(_dot)
      ..appendChild(_host)
      ..appendChild(el('span', className: 'spacer'))
      ..appendChild(_rtt)
      ..appendChild(_transport)
      ..appendChild(sessionMenu.element)
      ..appendChild(settings);
    connection.states.listen(_onState);
    connection.rtt.listen((ms) => _rtt.textContent = '$ms ms');
  }

  /// The connection being displayed.
  final Connection connection;
  final Strings strings;

  /// Root element.
  late final web.HTMLElement element;
  late final web.HTMLElement _dot;
  late final web.HTMLElement _host;
  late final web.HTMLElement _rtt;
  late final web.HTMLElement _transport;

  void _onState(ConnState state) {
    final (cls, title, session) = switch (state) {
      Live(:final name) => ('dot live', strings['status.connected'], name),
      Connecting() => ('dot connecting', strings['status.connecting'], ''),
      AuthRequired() => ('dot down', 'login required', ''),
      Attaching() => ('dot connecting', strings['status.connecting'], ''),
      Disconnected(:final reason, :final retryIn) => (
        'dot down',
        retryIn == null
            ? reason
            : '$reason, ${strings['status.retry']} ${retryIn.inSeconds}s',
        '',
      ),
    };
    _dot.className = cls;
    _dot.title = title;
    _host.title = title;
    if (state is Live) _transport.textContent = state.transport;
    if (state is! Live) _rtt.textContent = '';
  }
}
