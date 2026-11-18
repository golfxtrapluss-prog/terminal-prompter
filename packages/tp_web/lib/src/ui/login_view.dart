import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../api_client.dart';
import '../i18n/strings.dart';
import '../webauthn.dart';
import 'dom.dart';

/// Login page (docs/05, docs/16): passkey first when available, password
/// (+ TOTP code when enabled), or a backup code.
final class LoginView {
  LoginView({
    required this.api,
    required this.strings,
    required this.onLoggedIn,
    required this.host,
  });

  final ApiClient api;
  final Strings strings;
  final String host;

  /// Called after a successful login, with a notice to show (or null).
  final void Function(String? notice) onLoggedIn;

  late final web.HTMLElement element;
  late final web.HTMLElement _error;
  late final web.HTMLElement _passwordForm;
  late final web.HTMLElement _backupForm;
  late final web.HTMLInputElement _password;
  late final web.HTMLInputElement _totp;
  late final web.HTMLInputElement _backup;

  /// Builds the view; [methods] is `GET /api/auth/methods`.
  web.HTMLElement build(Map<String, Object?> methods) {
    final totpOn = methods['totp'] == true;
    final passkeys = methods['passkeys'] is int
        ? methods['passkeys']! as int
        : 0;
    element = el('div', className: 'login');
    final card = el('div', className: 'login-card');
    card
      ..appendChild(el('div', className: 'login-logo', text: '>_'))
      ..appendChild(el('h1', text: strings['login.title']))
      ..appendChild(el('p', className: 'muted', text: host));
    _error = el('div', className: 'login-error', text: '');
    _error.setAttribute('role', 'alert');
    card.appendChild(_error);

    if (passkeys > 0 && Passkeys.supported) {
      final pk = el(
        'button',
        className: 'primary wide',
        text: '🔑 ${strings['login.passkey']}',
      );
      pk.onclick = ((web.Event _) => _passkey()).toJS;
      card
        ..appendChild(pk)
        ..appendChild(el('div', className: 'login-or', text: '—'));
    }

    _passwordForm = el('form', className: 'login-form');
    _password = _input(
      'password',
      strings['login.password'],
      autocomplete: 'current-password',
    );
    _totp = _input('text', strings['login.totp'], autocomplete: 'one-time-code')
      ..inputMode = 'numeric'
      ..pattern = '[0-9]*'
      ..maxLength = 6;
    _passwordForm.appendChild(_labelled(strings['login.password'], _password));
    if (totpOn) {
      _passwordForm.appendChild(_labelled(strings['login.totp'], _totp));
    }
    _passwordForm.appendChild(
      el('button', className: 'primary wide', text: strings['login.submit']),
    );
    _passwordForm.addEventListener(
      'submit',
      ((web.Event e) {
        e.preventDefault();
        _login({'password': _password.value, if (totpOn) 'totp': _totp.value});
      }).toJS,
    );

    _backupForm = el('form', className: 'login-form hidden');
    _backup = _input('text', strings['login.backup'], autocomplete: 'off')
      ..autocapitalize = 'characters';
    _backupForm
      ..appendChild(_labelled(strings['login.backup'], _backup))
      ..appendChild(
        el('button', className: 'primary wide', text: strings['login.submit']),
      );
    _backupForm.addEventListener(
      'submit',
      ((web.Event e) {
        e.preventDefault();
        _login({'backup_code': _backup.value});
      }).toJS,
    );

    final toggle = el(
      'button',
      className: 'link',
      text: strings['login.useBackup'],
    );
    toggle.onclick = ((web.Event _) {
      final showBackup = _backupForm.classList.contains('hidden');
      _backupForm.classList.toggle('hidden', !showBackup);
      _passwordForm.classList.toggle('hidden', showBackup);
      toggle.textContent = showBackup
          ? strings['login.usePassword']
          : strings['login.useBackup'];
      (showBackup ? _backup : _password).focus();
    }).toJS;

    card
      ..appendChild(_passwordForm)
      ..appendChild(_backupForm)
      ..appendChild(toggle);
    element.appendChild(card);
    return element;
  }

  void focus() => _password.focus();

  Future<void> _login(Map<String, Object?> body) async {
    _error.textContent = '';
    _setBusy(true);
    try {
      final r = await api.post('login', body);
      final left = r['backup_codes_left'];
      onLoggedIn(
        left is int
            ? '${strings['login.backupLeft']} $left. ${strings['login.backupAdvice']}'
            : null,
      );
    } on ApiException catch (e) {
      _showError(e);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _passkey() async {
    _error.textContent = '';
    try {
      final options = await api.post('auth/passkey/login/options');
      final assertion = await Passkeys.get(options);
      await api.post('auth/passkey/login', assertion);
      onLoggedIn(null);
    } on ApiException catch (e) {
      _showError(e);
    } on Object {
      _error.textContent = strings['login.passkeyFailed'];
    }
  }

  void _showError(ApiException e) {
    final wait = e.retryAfter;
    final waitText = wait == null
        ? ''
        : wait >= 120
        ? ' ${(wait / 60).ceil()} ${strings['login.minutes']}.'
        : ' $wait ${strings['login.seconds']}.';
    _error.textContent = switch (e.code) {
      'locked' => '${strings['login.locked']}$waitText',
      'rate_limited' => '${strings['login.rateLimited']}$waitText',
      'network' => strings['login.network'],
      'passkey_rejected' => strings['login.passkeyFailed'],
      _ => strings['login.invalid'],
    };
    _password.value = '';
    _totp.value = '';
  }

  void _setBusy(bool busy) {
    for (final form in [_passwordForm, _backupForm]) {
      final button = form.querySelector('button') as web.HTMLButtonElement?;
      button?.disabled = busy;
    }
  }

  web.HTMLInputElement _input(
    String type,
    String label, {
    required String autocomplete,
  }) {
    final input = el('input', label: label) as web.HTMLInputElement;
    input
      ..type = type
      ..autocomplete = autocomplete
      ..required = true
      ..spellcheck = false;
    input.setAttribute('autocorrect', 'off');
    input.setAttribute('autocapitalize', 'off');
    return input;
  }

  web.HTMLElement _labelled(String text, web.HTMLElement control) {
    final label = el('label');
    label
      ..appendChild(el('span', text: text))
      ..appendChild(control);
    return label;
  }
}
