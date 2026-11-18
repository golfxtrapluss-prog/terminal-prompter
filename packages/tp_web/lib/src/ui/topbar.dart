import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../conn/connection.dart';
import '../i18n/strings.dart';
import 'dom.dart';

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
    _session = el('span', className: 'session');
    _rtt = el('span', className: 'rtt');
    final transport = el('span', className: 'transport', text: 'WS');
    final newSession =
        el('button', text: strings['newSession']) as web.HTMLButtonElement;
    newSession.onclick = ((web.Event _) => connection.newSession()).toJS;
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
      ..appendChild(_session)
      ..appendChild(el('span', className: 'spacer'))
      ..appendChild(_rtt)
      ..appendChild(transport)
      ..appendChild(newSession)
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
  late final web.HTMLElement _session;
  late final web.HTMLElement _rtt;

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
    _session.textContent = session;
    _host.title = title;
    if (state is! Live) _rtt.textContent = '';
  }
}
