import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../auth/auth_service.dart';
import '../auth/encoding.dart';
import '../auth/login_sessions.dart';
import '../auth/webauthn.dart';
import '../config/config.dart';
import '../session/session_manager.dart';

/// Cookie names.
const String sessionCookie = 'tp_session';
const String csrfCookie = 'tp_csrf';

/// Header carrying the CSRF token (double submit, docs/05).
const String csrfHeader = 'x-tp-csrf';

/// Request checks shared by the JSON API and the WebSocket upgrade.
final class RequestGuard {
  RequestGuard(this.config);

  final AgentConfig config;

  /// Client address, honouring `X-Forwarded-For` only from a local reverse
  /// proxy in proxy mode (otherwise every user would share 127.0.0.1).
  String clientIp(HttpRequest request) {
    final remote = request.connectionInfo?.remoteAddress;
    final forwarded = request.headers.value('x-forwarded-for');
    if (config.mode == AgentMode.proxy &&
        remote != null &&
        remote.isLoopback &&
        forwarded != null) {
      final last = forwarded.split(',').last.trim();
      if (last.isNotEmpty && last.length <= 64) return last;
    }
    return remote?.address ?? 'unknown';
  }

  String userAgent(HttpRequest request) {
    final ua = request.headers.value(HttpHeaders.userAgentHeader) ?? '';
    return ua.length > 256 ? ua.substring(0, 256) : ua;
  }

  ClientInfo client(HttpRequest request) =>
      ClientInfo(ip: clientIp(request), userAgent: userAgent(request));

  /// The request's `Origin` if it is allowed (docs/05: strict check against
  /// `public_origin`; without one, the origin must match the Host header).
  String? allowedOrigin(HttpRequest request) {
    final origin = request.headers.value('origin');
    if (origin == null) return null;
    final configured = config.publicOrigin;
    if (configured != null) {
      return origin == _originOf(configured) ? origin : null;
    }
    final host = request.headers.value(HttpHeaders.hostHeader);
    if (host == null) return null;
    return origin == 'http://$host' || origin == 'https://$host'
        ? origin
        : null;
  }

  /// WebAuthn relying party for an allowed [origin].
  RelyingParty relyingParty(String origin) =>
      RelyingParty(id: Uri.parse(origin).host, origin: origin);

  static String _originOf(Uri uri) => uri.hasPort
      ? '${uri.scheme}://${uri.host}:${uri.port}'
      : '${uri.scheme}://${uri.host}';
}

/// Thrown inside handlers to answer with an error status.
final class ApiError implements Exception {
  const ApiError(this.status, this.code, {this.retryAfter});

  final int status;
  final String code;
  final Duration? retryAfter;
}

/// JSON API under `<base>/api/` (docs/02 "HTTP-endepunkter").
final class Api {
  Api({
    required this.config,
    required this.auth,
    required this.sessions,
    required this.guard,
    required this.agentVersion,
  });

  static const int maxBody = 64 * 1024;

  final AgentConfig config;
  final AuthService auth;
  final SessionManager sessions;
  final RequestGuard guard;
  final String agentVersion;
  final Logger _log = Logger('api');

  /// Returns the valid login for [request], or null.
  LoginSession? currentLogin(HttpRequest request, {bool touch = true}) {
    final token = _cookie(request, sessionCookie);
    return auth.sessions.validate(
      token,
      userAgent: guard.userAgent(request),
      touch: touch,
    );
  }

  /// Handles `api/<path>`; the caller has applied security headers.
  Future<void> handle(HttpRequest request, String path) async {
    final response = request.response;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      final result = await _route(request, path);
      await _json(response, 200, result);
    } on ApiError catch (e) {
      if (e.retryAfter != null) {
        response.headers.set(
          HttpHeaders.retryAfterHeader,
          '${e.retryAfter!.inSeconds.clamp(1, 86400)}',
        );
      }
      await _json(response, e.status, {'error': e.code});
    } on FormatException {
      await _json(response, 400, {'error': 'bad_request'});
    } on WebAuthnException catch (e) {
      _log.info({'msg': 'webauthn_rejected', 'reason': e.message});
      await _json(response, 400, {'error': 'passkey_rejected'});
    }
  }

  Future<Object?> _route(HttpRequest request, String path) async {
    final method = request.method;
    if (method == 'GET') {
      switch (path) {
        case 'auth/methods':
          return {
            'totp': auth.totpEnabled,
            'passkeys': auth.state.passkeys.length,
          };
        case 'me':
          return _me(request, _requireLogin(request));
      }
      throw const ApiError(404, 'not_found');
    }
    if (method != 'POST') throw const ApiError(405, 'method_not_allowed');

    // Every POST: JSON only, from our own origin (docs/05 CSRF).
    final ct = request.headers.contentType;
    if (ct == null || ct.mimeType != 'application/json') {
      throw const ApiError(415, 'json_required');
    }
    final origin = guard.allowedOrigin(request);
    if (origin == null) throw const ApiError(403, 'bad_origin');
    final body = await _readJson(request);
    final client = guard.client(request);

    switch (path) {
      case 'login':
        final backup = body['backup_code'];
        final LoginResult result;
        if (backup is String) {
          result = await auth.loginWithBackupCode(backup, client);
        } else {
          final password = body['password'];
          if (password is! String) throw const ApiError(400, 'bad_request');
          final totp = body['totp'];
          result = await auth.loginWithPassword(
            password,
            totp is String ? totp : null,
            client,
          );
        }
        return _loginResponse(request, result);
      case 'auth/passkey/login/options':
        return auth.passkeyLoginOptions(guard.relyingParty(origin));
      case 'auth/passkey/login':
        return _loginResponse(
          request,
          auth.loginWithPasskey(
            challengeId: _str(body, 'challengeId'),
            credentialId: _str(body, 'id'),
            clientDataJson: b64UrlDecode(_str(body, 'clientDataJSON')),
            authenticatorData: b64UrlDecode(_str(body, 'authenticatorData')),
            signature: b64UrlDecode(_str(body, 'signature')),
            client: client,
          ),
        );
    }

    // Everything below needs a login and the CSRF header.
    final login = _requireLogin(request);
    final csrf = request.headers.value(csrfHeader);
    if (csrf == null || !constantTimeEqualsString(csrf, login.csrf)) {
      throw const ApiError(403, 'bad_csrf');
    }

    switch (path) {
      case 'logout':
        auth.logout(login);
        _clearCookies(request.response);
        return {'ok': true};
      case 'logout-all':
        final n = auth.logoutAll(login);
        _clearCookies(request.response);
        return {'ended': n};
      case 'auth/logins/revoke':
        if (!auth.sessions.revoke(_str(body, 'id'))) {
          throw const ApiError(404, 'not_found');
        }
        return {'ok': true};
      case 'auth/passkey/register/options':
        return auth.passkeyRegisterOptions(guard.relyingParty(origin));
      case 'auth/passkey/register':
        final cred = auth.registerPasskey(
          challengeId: _str(body, 'challengeId'),
          clientDataJson: b64UrlDecode(_str(body, 'clientDataJSON')),
          attestationObject: b64UrlDecode(_str(body, 'attestationObject')),
          name: body['name'] is String ? (body['name']! as String) : '',
          by: login,
        );
        return {'id': cred.idB64, 'name': cred.name};
      case 'auth/passkey/remove':
        if (!auth.removePasskey(_str(body, 'id'), login)) {
          throw const ApiError(404, 'not_found');
        }
        return {'ok': true};
      case 'auth/backup-codes':
        return {'codes': await auth.generateBackupCodes(login)};
    }
    throw const ApiError(404, 'not_found');
  }

  Map<String, Object?> _me(HttpRequest request, LoginSession login) {
    final codes = auth.state.backupCodes;
    return {
      'agent': agentVersion,
      'host': Platform.localHostname,
      'login': {'id': login.id, 'method': login.method.name},
      'logins': [
        for (final s in auth.sessions.list())
          {
            'id': s.id,
            'created': s.created.toUtc().toIso8601String(),
            'last_seen': s.lastSeen.toUtc().toIso8601String(),
            'ip': s.ip,
            'ua': s.userAgent,
            'method': s.method.name,
            'current': s.tokenHash == login.tokenHash,
          },
      ],
      'passkeys': [
        for (final p in auth.state.passkeys)
          {
            'id': p.idB64,
            'name': p.name,
            'created': p.created.toIso8601String(),
            if (p.lastUsed != null) 'last_used': p.lastUsed!.toIso8601String(),
          },
      ],
      'backup_codes': {
        'remaining': codes?.remaining ?? 0,
        if (codes != null) 'generated': codes.generated.toIso8601String(),
      },
      'totp': auth.totpEnabled,
      'sessions': sessions.list().length,
    };
  }

  Map<String, Object?> _loginResponse(HttpRequest request, LoginResult result) {
    switch (result) {
      case LoginDenied(:final code, :final retryAfter):
        final status = code == 'invalid_credentials' ? 401 : 429;
        throw ApiError(status, code, retryAfter: retryAfter);
      case LoginOk(:final login, :final backupCodesLeft):
        _setCookies(request.response, login);
        return {
          'ok': true,
          'csrf': login.session.csrf,
          'backup_codes_left': ?backupCodesLeft,
        };
    }
  }

  LoginSession _requireLogin(HttpRequest request) =>
      currentLogin(request) ?? (throw const ApiError(401, 'auth_required'));

  void _setCookies(HttpResponse response, NewLogin login) {
    final maxAge = config.auth.sessionTtl.inSeconds;
    response.cookies
      ..add(
        Cookie(sessionCookie, login.token)
          ..httpOnly = true
          ..secure = true
          ..sameSite = SameSite.strict
          ..path = config.basePath
          ..maxAge = maxAge,
      )
      ..add(
        Cookie(csrfCookie, login.session.csrf)
          ..httpOnly = false
          ..secure = true
          ..sameSite = SameSite.strict
          ..path = config.basePath
          ..maxAge = maxAge,
      );
  }

  void _clearCookies(HttpResponse response) {
    for (final name in [sessionCookie, csrfCookie]) {
      response.cookies.add(
        Cookie(name, '')
          ..httpOnly = name == sessionCookie
          ..secure = true
          ..sameSite = SameSite.strict
          ..path = config.basePath
          ..maxAge = 0,
      );
    }
  }

  static String? _cookie(HttpRequest request, String name) {
    for (final c in request.cookies) {
      if (c.name == name) return c.value;
    }
    return null;
  }

  static String _str(Map<String, Object?> body, String key) {
    final v = body[key];
    if (v is! String || v.isEmpty || v.length > 16 * 1024) {
      throw const ApiError(400, 'bad_request');
    }
    return v;
  }

  static Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > maxBody) throw const ApiError(413, 'too_large');
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(builder.takeBytes()));
    } on FormatException {
      throw const ApiError(400, 'bad_request');
    }
    if (json is! Map<String, Object?>) throw const ApiError(400, 'bad_request');
    return json;
  }

  static Future<void> _json(
    HttpResponse response,
    int status,
    Object? body,
  ) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await response.close();
  }
}
