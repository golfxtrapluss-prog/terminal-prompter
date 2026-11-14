import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../conn/connection.dart';
import 'dom.dart';

/// Top bar: connection dot, host, session name, RTT, transport, actions.
final class TopBar {
  /// Builds the bar and wires it to [connection].
  TopBar(this.connection) {
    element = el('header', className: 'topbar');
    _dot = el('span', className: 'dot', title: 'disconnected');
    _host = el('span', className: 'host', text: connection.host);
    _session = el('span', className: 'session');
    _rtt = el('span', className: 'rtt');
    final transport = el('span', className: 'transport', text: 'WS');
    final newSession =
        el('button', text: 'New session') as web.HTMLButtonElement;
    newSession.onclick = ((web.Event _) => connection.newSession()).toJS;
    element
      ..appendChild(_dot)
      ..appendChild(_host)
      ..appendChild(_session)
      ..appendChild(el('span', className: 'spacer'))
      ..appendChild(_rtt)
      ..appendChild(transport)
      ..appendChild(newSession);
    connection.states.listen(_onState);
    connection.rtt.listen((ms) => _rtt.textContent = '$ms ms');
  }

  /// The connection being displayed.
  final Connection connection;

  /// Root element.
  late final web.HTMLElement element;
  late final web.HTMLElement _dot;
  late final web.HTMLElement _host;
  late final web.HTMLElement _session;
  late final web.HTMLElement _rtt;

  void _onState(ConnState state) {
    final (cls, title, session) = switch (state) {
      Live(:final name) => ('dot live', 'connected', name),
      Connecting() => ('dot connecting', 'connecting', ''),
      Disconnected(:final reason) => ('dot down', reason, ''),
    };
    _dot.className = cls;
    _dot.title = title;
    _session.textContent = session;
    _host.title = title;
    if (state is! Live) _rtt.textContent = '';
  }
}
