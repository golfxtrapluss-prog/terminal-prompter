import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../api_client.dart';
import '../i18n/strings.dart';
import '../webauthn.dart';
import 'dom.dart';

/// Settings > Security (docs/05, docs/17): logged-in devices, passkeys,
/// backup codes and TOTP status.
final class SecurityPanel {
  SecurityPanel({
    required this.api,
    required this.strings,
    required this.onLoggedOut,
  }) {
    element = el('aside', className: 'settings security hidden');
  }

  final ApiClient api;
  final Strings strings;

  /// Called after this device logged out.
  final void Function() onLoggedOut;
  late final web.HTMLElement element;

  bool get isOpen => !element.classList.contains('hidden');

  void close() => element.classList.add('hidden');

  Future<void> open() async {
    element.classList.remove('hidden');
    await _render();
  }

  Future<void> _render({List<String>? newCodes, String? notice}) async {
    element.textContent = '';
    final header = el('div', className: 'panel-header');
    final closeBtn = el('button', text: '×', label: strings['settings.close']);
    closeBtn.onclick = ((web.Event _) => close()).toJS;
    header
      ..appendChild(el('h2', text: strings['security']))
      ..appendChild(closeBtn);
    element.appendChild(header);
    if (notice != null) {
      element.appendChild(el('div', className: 'notice', text: notice));
    }

    final Map<String, Object?> me;
    try {
      me = await api.get('me');
    } on ApiException catch (e) {
      if (e.status == 401) {
        onLoggedOut();
        return;
      }
      element.appendChild(
        el('p', className: 'settings-error', text: strings['login.network']),
      );
      return;
    }

    if (newCodes != null) {
      element.appendChild(_codesBox(newCodes));
      return;
    }

    // Logins
    element.appendChild(el('h3', text: strings['security.logins']));
    final logins =
        (me['logins'] as List?)?.cast<Map<String, Object?>>() ?? const [];
    for (final l in logins) {
      final row = el('div', className: 'sec-row');
      final current = l['current'] == true;
      row.appendChild(
        el(
          'div',
          className: 'sec-main',
          text:
              '${_device(l['ua'] as String? ?? '')}${current ? ' (${strings['security.thisDevice']})' : ''}',
        ),
      );
      row.appendChild(
        el(
          'div',
          className: 'muted',
          text:
              '${l['ip']} · ${_ago(l['last_seen'] as String?)} · ${l['method']}',
        ),
      );
      if (!current) {
        final revoke = el('button', text: strings['security.revoke']);
        revoke.onclick = ((web.Event _) async {
          await api.post('auth/logins/revoke', {'id': l['id']});
          await _render();
        }).toJS;
        row.appendChild(revoke);
      }
      element.appendChild(row);
    }
    final actions = el('div', className: 'settings-actions');
    final logout = el('button', text: strings['security.logout']);
    logout.onclick = ((web.Event _) async {
      await api.post('logout');
      onLoggedOut();
    }).toJS;
    final logoutAll = el(
      'button',
      className: 'danger',
      text: strings['security.logoutAll'],
    );
    logoutAll.onclick = ((web.Event _) async {
      await api.post('logout-all');
      onLoggedOut();
    }).toJS;
    actions
      ..appendChild(logout)
      ..appendChild(logoutAll);
    element.appendChild(actions);

    // Passkeys
    element.appendChild(el('h3', text: strings['security.passkeys']));
    final passkeys =
        (me['passkeys'] as List?)?.cast<Map<String, Object?>>() ?? const [];
    if (passkeys.isEmpty) {
      element.appendChild(
        el('p', className: 'muted', text: strings['security.noPasskeys']),
      );
    }
    for (final p in passkeys) {
      final row = el('div', className: 'sec-row');
      row
        ..appendChild(el('div', className: 'sec-main', text: '🔑 ${p['name']}'))
        ..appendChild(
          el(
            'div',
            className: 'muted',
            text:
                '${strings['security.lastUsed']}: ${_ago(p['last_used'] as String?)}',
          ),
        );
      final remove = el('button', text: strings['security.remove']);
      remove.onclick = ((web.Event _) async {
        if (!web.window.confirm(strings['security.confirmRemove'])) return;
        await api.post('auth/passkey/remove', {'id': p['id']});
        await _render();
      }).toJS;
      row.appendChild(remove);
      element.appendChild(row);
    }
    final add = el(
      'button',
      className: 'primary',
      text: strings['security.addPasskey'],
    );
    add.onclick = ((web.Event _) => _addPasskey()).toJS;
    element.appendChild(add);

    // Backup codes
    element.appendChild(el('h3', text: strings['security.backupCodes']));
    final codes = me['backup_codes'] as Map<String, Object?>? ?? const {};
    final left = codes['remaining'] as int? ?? 0;
    if (left == 0) {
      element.appendChild(
        el('p', className: 'warn', text: strings['security.backupNone']),
      );
    } else {
      element.appendChild(
        el('p', text: '$left ${strings['security.backupLeft']}'),
      );
      if (left < 3) {
        element.appendChild(
          el('p', className: 'warn', text: strings['security.backupLow']),
        );
      }
    }
    final generate = el('button', text: strings['security.backupGenerate']);
    generate.onclick = ((web.Event _) async {
      if (left > 0 && !web.window.confirm(strings['security.backupConfirm'])) {
        return;
      }
      final r = await api.post('auth/backup-codes');
      await _render(newCodes: (r['codes']! as List).cast<String>());
    }).toJS;
    element.appendChild(generate);

    // TOTP
    element
      ..appendChild(el('h3', text: strings['security.totp']))
      ..appendChild(
        el(
          'p',
          className: 'muted',
          text: me['totp'] == true
              ? strings['security.totpOn']
              : strings['security.totpOff'],
        ),
      );
  }

  Future<void> _addPasskey() async {
    if (!Passkeys.supported) {
      web.window.alert(strings['security.passkeyUnsupported']);
      return;
    }
    final name = web.window.prompt(
      strings['security.passkeyName'],
      _device(web.window.navigator.userAgent),
    );
    if (name == null) return;
    try {
      final options = await api.post('auth/passkey/register/options');
      final attestation = await Passkeys.create(options);
      await api.post('auth/passkey/register', {...attestation, 'name': name});
      await _render(notice: strings['security.passkeyAdded']);
    } on Object {
      await _render(notice: strings['login.passkeyFailed']);
    }
  }

  web.HTMLElement _codesBox(List<String> codes) {
    final box = el('div', className: 'codes');
    box.appendChild(
      el('p', className: 'warn', text: strings['security.backupShown']),
    );
    final list = el('pre', className: 'code-list', text: codes.join('\n'));
    box.appendChild(list);
    final actions = el('div', className: 'settings-actions');
    final download = el('button', text: strings['security.download']);
    download.onclick = ((web.Event _) {
      final text =
          'Terminal Prompter backup codes (${web.window.location.host})\n'
          'Each code works once.\n\n${codes.join('\n')}\n';
      final blob = web.Blob(
        [text.toJS].toJS,
        web.BlobPropertyBag(type: 'text/plain'),
      );
      final url = web.URL.createObjectURL(blob);
      final a = web.document.createElement('a') as web.HTMLAnchorElement
        ..href = url
        ..download = 'terminal-prompter-backup-codes.txt';
      a.click();
      web.URL.revokeObjectURL(url);
    }).toJS;
    final print = el('button', text: strings['security.print']);
    print.onclick = ((web.Event _) => web.window.print()).toJS;
    final done = el(
      'button',
      className: 'primary',
      text: strings['security.done'],
    );
    done.onclick = ((web.Event _) => _render()).toJS;
    actions
      ..appendChild(download)
      ..appendChild(print)
      ..appendChild(done);
    box.appendChild(actions);
    return box;
  }

  static String _device(String ua) {
    if (ua.contains('iPhone')) return 'iPhone';
    if (ua.contains('iPad')) return 'iPad';
    if (ua.contains('Android')) return 'Android';
    if (ua.contains('Mac OS X')) return 'Mac';
    if (ua.contains('Windows')) return 'Windows';
    if (ua.contains('Linux')) return 'Linux';
    return ua.isEmpty ? '?' : ua.split(' ').first;
  }

  String _ago(String? iso) {
    if (iso == null) return strings['security.never'];
    final t = DateTime.tryParse(iso);
    if (t == null) return iso;
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '<1 min';
    if (d.inHours < 1) return '${d.inMinutes} min';
    if (d.inDays < 1) return '${d.inHours} h';
    return '${d.inDays} d';
  }
}
