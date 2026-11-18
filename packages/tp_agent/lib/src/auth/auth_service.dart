import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../audit/audit_log.dart';
import '../config/config.dart';
import 'auth_store.dart';
import 'backup_codes.dart';
import 'encoding.dart';
import 'login_sessions.dart';
import 'password.dart';
import 'rate_limit.dart';
import 'totp.dart';
import 'webauthn.dart';

/// Outcome of a login attempt.
sealed class LoginResult {
  const LoginResult();
}

/// Logged in; [login.token] goes into the session cookie.
final class LoginOk extends LoginResult {
  const LoginOk(this.login, {this.backupCodesLeft});

  final NewLogin login;

  /// Set when a backup code was used: how many remain.
  final int? backupCodesLeft;
}

/// Why a login was refused. [code] is safe to show the client; it never
/// says which factor was wrong.
final class LoginDenied extends LoginResult {
  const LoginDenied(this.code, {this.retryAfter});

  /// `invalid_credentials`, `rate_limited`, `locked`, `bad_request`.
  final String code;
  final Duration? retryAfter;
}

/// Who/where a request comes from, for limits and the audit log.
final class ClientInfo {
  const ClientInfo({required this.ip, required this.userAgent});

  final String ip;
  final String userAgent;
}

/// A pending WebAuthn challenge.
final class _Challenge {
  _Challenge(this.bytes, this.kind, this.rp, this.expires);

  final Uint8List bytes;
  final String kind;
  final RelyingParty rp;
  final DateTime expires;
}

/// Authentication for the single agent account (docs/05, docs/17): password
/// (+ optional TOTP), backup codes, passkeys, login sessions, limits and
/// audit. HTTP-independent so it can be tested directly.
final class AuthService {
  AuthService({
    required this.config,
    required this.store,
    required this.audit,
    this.backupCodeCost = Argon2Cost.backupCode,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       sessions = LoginSessions(
         ttl: config.auth.sessionTtl,
         idleTimeout: config.auth.idleTimeout,
         clock: clock,
       ),
       limiter = LoginLimiter(
         maxFailures: config.auth.maxFailedLogins,
         lockout: config.auth.lockout,
         clock: clock,
       ),
       state = store.load();

  static const Duration challengeLifetime = Duration(minutes: 5);

  final AgentConfig config;
  final AuthStore store;
  final AuditLog audit;
  final Argon2Cost backupCodeCost;
  final LoginSessions sessions;
  final LoginLimiter limiter;
  AuthState state;
  final DateTime Function() _clock;
  final Map<String, _Challenge> _challenges = {};
  final Logger _log = Logger('auth');

  bool get totpEnabled => config.auth.totpSecret.isNotEmpty;

  // ---- password (+ TOTP) ----

  Future<LoginResult> loginWithPassword(
    String password,
    String? totpCode,
    ClientInfo client,
  ) async {
    final gate = _gate(client, 'password');
    if (gate != null) return gate;
    var ok =
        password.isNotEmpty &&
        password.length <= 1024 &&
        await verifyPasswordAsync(password, config.auth.passwordHash);
    int? step;
    if (ok && totpEnabled) {
      step = Totp.fromBase32(
        config.auth.totpSecret,
      ).verify(totpCode ?? '', _clock(), lastUsedStep: state.totpLastStep);
      ok = step != null;
    }
    if (!ok) return _fail(client, 'password');
    if (step != null) {
      state.totpLastStep = step;
      _save();
    }
    return _succeed(client, LoginMethod.password);
  }

  // ---- backup codes ----

  Future<LoginResult> loginWithBackupCode(
    String code,
    ClientInfo client,
  ) async {
    final gate = _gate(client, 'backup_code');
    if (gate != null) return gate;
    final set = state.backupCodes;
    if (set == null || code.length > 64) return _fail(client, 'backup_code');
    final index = await Isolate.run(() => set.match(code));
    if (index == null) return _fail(client, 'backup_code');
    set.consume(index);
    _save();
    audit.record('backup_code_used', {
      'ip': client.ip,
      'remaining': set.remaining,
    });
    final result = _succeed(client, LoginMethod.backupCode);
    return LoginOk(result.login, backupCodesLeft: set.remaining);
  }

  /// Generates a new set (old codes stop working). Returns the plain codes,
  /// which are shown once and never stored.
  Future<List<String>> generateBackupCodes(LoginSession by) async {
    final cost = backupCodeCost;
    final generated = await Isolate.run(
      () => BackupCodeSet.generate(cost: cost),
    );
    state.backupCodes = generated.stored;
    _save();
    audit.record('backup_codes_generated', {'ip': by.ip, 'login': by.id});
    return generated.codes;
  }

  // ---- passkeys ----

  /// Starts a passkey login. Not rate limited per se (it reveals nothing),
  /// but challenges are capped.
  Map<String, Object?> passkeyLoginOptions(RelyingParty rp) {
    final (id, challenge) = _newChallenge('get', rp);
    return {
      'challengeId': id,
      'challenge': b64Url(challenge),
      'rpId': rp.id,
      'timeout': challengeLifetime.inMilliseconds,
      'userVerification': 'required',
      'allowCredentials': [
        for (final p in state.passkeys) {'type': 'public-key', 'id': p.idB64},
      ],
    };
  }

  LoginResult loginWithPasskey({
    required String challengeId,
    required String credentialId,
    required Uint8List clientDataJson,
    required Uint8List authenticatorData,
    required Uint8List signature,
    required ClientInfo client,
  }) {
    final wait = limiter.attempt(client.ip);
    if (wait != null) return LoginDenied('rate_limited', retryAfter: wait);
    final challenge = _takeChallenge(challengeId, 'get');
    final credential = state.passkeys
        .where((p) => p.idB64 == credentialId)
        .firstOrNull;
    if (challenge == null || credential == null) {
      return _deny(client, 'passkey', 'unknown challenge or credential');
    }
    try {
      WebAuthnVerifier(challenge.rp).verifyAssertion(
        credential: credential,
        clientDataJson: clientDataJson,
        authenticatorData: authenticatorData,
        signature: signature,
        expectedChallenge: challenge.bytes,
        now: _clock(),
      );
    } on WebAuthnException catch (e) {
      return _deny(client, 'passkey', e.message);
    }
    _save();
    // Passkey logins are not subject to the password lockout: an attacker
    // guessing passwords must not be able to lock the owner out.
    return _succeed(client, LoginMethod.passkey, detail: credential.name);
  }

  Map<String, Object?> passkeyRegisterOptions(RelyingParty rp) {
    final (id, challenge) = _newChallenge('create', rp);
    return {
      'challengeId': id,
      'challenge': b64Url(challenge),
      'rp': {'id': rp.id, 'name': rp.name},
      'user': {
        'id': state.userHandle,
        'name': 'tp@${rp.id}',
        'displayName': 'Terminal Prompter (${rp.id})',
      },
      'pubKeyCredParams': [
        {'type': 'public-key', 'alg': -7},
      ],
      'timeout': challengeLifetime.inMilliseconds,
      'attestation': 'none',
      'authenticatorSelection': {
        'residentKey': 'preferred',
        'userVerification': 'required',
      },
      'excludeCredentials': [
        for (final p in state.passkeys) {'type': 'public-key', 'id': p.idB64},
      ],
    };
  }

  /// Verifies and stores a new passkey. Throws [WebAuthnException].
  StoredCredential registerPasskey({
    required String challengeId,
    required Uint8List clientDataJson,
    required Uint8List attestationObject,
    required String name,
    required LoginSession by,
  }) {
    final challenge = _takeChallenge(challengeId, 'create');
    if (challenge == null) {
      throw const WebAuthnException('unknown or expired challenge');
    }
    final credential = WebAuthnVerifier(challenge.rp).verifyRegistration(
      clientDataJson: clientDataJson,
      attestationObject: attestationObject,
      expectedChallenge: challenge.bytes,
      name: name.trim().isEmpty
          ? 'Passkey ${state.passkeys.length + 1}'
          : name.trim(),
      now: _clock(),
    );
    if (state.passkeys.any((p) => p.idB64 == credential.idB64)) {
      throw const WebAuthnException('passkey already registered');
    }
    if (state.passkeys.length >= 20) {
      throw const WebAuthnException('too many passkeys');
    }
    state.passkeys.add(credential);
    _save();
    audit.record('passkey_added', {
      'ip': by.ip,
      'name': credential.name,
      'login': by.id,
    });
    return credential;
  }

  bool removePasskey(String id, LoginSession by) {
    final before = state.passkeys.length;
    state.passkeys.removeWhere((p) => p.idB64 == id);
    if (state.passkeys.length == before) return false;
    _save();
    audit.record('passkey_removed', {'ip': by.ip, 'login': by.id});
    return true;
  }

  // ---- sessions ----

  void logout(LoginSession session) {
    sessions.end(session);
    audit.record('logout', {'ip': session.ip, 'login': session.id});
  }

  int logoutAll(LoginSession by) {
    final n = sessions.endAll();
    audit.record('logout_all', {'ip': by.ip, 'count': n});
    return n;
  }

  // ---- internals ----

  LoginDenied? _gate(ClientInfo client, String method) {
    final wait = limiter.attempt(client.ip);
    if (wait != null) {
      audit.record('login_fail', {
        'ip': client.ip,
        'method': method,
        'reason': 'rate_limited',
      });
      return LoginDenied('rate_limited', retryAfter: wait);
    }
    final locked = limiter.lockedUntil;
    if (locked != null) {
      audit.record('login_fail', {
        'ip': client.ip,
        'method': method,
        'reason': 'locked',
      });
      return LoginDenied('locked', retryAfter: locked.difference(_clock()));
    }
    return null;
  }

  LoginDenied _fail(ClientInfo client, String method) {
    final lockedNow = limiter.failure();
    audit.record('login_fail', {
      'ip': client.ip,
      'ua': client.userAgent,
      'method': method,
    });
    if (lockedNow) {
      audit.record('lockout', {
        'ip': client.ip,
        'until': limiter.lockedUntil?.toUtc().toIso8601String(),
      });
      _log.warning({'msg': 'login_lockout', 'ip': client.ip});
    }
    return const LoginDenied('invalid_credentials');
  }

  LoginDenied _deny(ClientInfo client, String method, String reason) {
    audit.record('login_fail', {
      'ip': client.ip,
      'ua': client.userAgent,
      'method': method,
      'reason': reason,
    });
    return const LoginDenied('invalid_credentials');
  }

  LoginOk _succeed(ClientInfo client, LoginMethod method, {String? detail}) {
    limiter.success();
    final login = sessions.create(
      ip: client.ip,
      userAgent: client.userAgent,
      method: method,
    );
    audit.record('login_ok', {
      'ip': client.ip,
      'ua': client.userAgent,
      'method': method.name,
      'login': login.session.id,
      'passkey': ?detail,
    });
    return LoginOk(login);
  }

  (String, Uint8List) _newChallenge(String kind, RelyingParty rp) {
    final now = _clock();
    _challenges.removeWhere((_, c) => c.expires.isBefore(now));
    if (_challenges.length > 1000) _challenges.clear();
    final id = b64Url(randomBytes(16));
    final bytes = randomBytes(32);
    _challenges[id] = _Challenge(bytes, kind, rp, now.add(challengeLifetime));
    return (id, bytes);
  }

  _Challenge? _takeChallenge(String id, String kind) {
    final c = _challenges.remove(id);
    if (c == null || c.kind != kind || c.expires.isBefore(_clock())) {
      return null;
    }
    return c;
  }

  void _save() {
    try {
      store.save(state);
    } on FileSystemException catch (e, st) {
      _log.severe({'msg': 'auth_state_save_failed', 'path': store.path}, e, st);
      rethrow;
    }
  }
}
