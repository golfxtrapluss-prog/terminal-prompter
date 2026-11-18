import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'encoding.dart';

/// How a login was established.
enum LoginMethod { password, passkey, backupCode }

/// One logged-in browser (docs/05 "Sesjonskapring"): only the SHA-256 of
/// the token is kept in memory; the token itself lives in an HttpOnly cookie.
final class LoginSession {
  LoginSession({
    required this.tokenHash,
    required this.csrf,
    required this.created,
    required this.ip,
    required this.userAgent,
    required this.method,
  }) : lastSeen = created;

  final String tokenHash;
  final String csrf;
  final DateTime created;
  final String ip;
  final String userAgent;
  final LoginMethod method;
  DateTime lastSeen;

  /// Short public identifier for lists and revocation (not the token).
  String get id => tokenHash.substring(0, 12);
}

/// Result of [LoginSessions.create]: the secret token goes into the cookie.
final class NewLogin {
  const NewLogin(this.token, this.session);

  final String token;
  final LoginSession session;
}

/// In-memory login sessions with absolute and idle expiry. An agent restart
/// logs everyone out, which is acceptable and safe.
final class LoginSessions {
  LoginSessions({
    required this.ttl,
    required this.idleTimeout,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final Duration idleTimeout;
  final DateTime Function() _clock;
  final Map<String, LoginSession> _byHash = {};

  /// Called when a session ends (logout, expiry, revocation) so open
  /// WebSockets of that login can be closed.
  void Function(LoginSession session)? onEnded;

  static String hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  NewLogin create({
    required String ip,
    required String userAgent,
    required LoginMethod method,
  }) {
    final token = b64Url(randomBytes(32));
    final session = LoginSession(
      tokenHash: hashToken(token),
      csrf: b64Url(randomBytes(32)),
      created: _clock(),
      ip: ip,
      userAgent: userAgent,
      method: method,
    );
    _byHash[session.tokenHash] = session;
    return NewLogin(token, session);
  }

  /// Looks up a valid session for [token] and refreshes its idle timer. A
  /// different User-Agent ends the session (weak binding, docs/05).
  LoginSession? validate(
    String? token, {
    required String userAgent,
    bool touch = true,
  }) {
    if (token == null || token.isEmpty || token.length > 128) return null;
    final session = _byHash[hashToken(token)];
    if (session == null) return null;
    final now = _clock();
    if (now.difference(session.created) > ttl ||
        now.difference(session.lastSeen) > idleTimeout ||
        session.userAgent != userAgent) {
      end(session);
      return null;
    }
    if (touch) session.lastSeen = now;
    return session;
  }

  /// True while [session] exists and has not expired.
  bool isActive(LoginSession session) {
    if (!identical(_byHash[session.tokenHash], session)) return false;
    final now = _clock();
    if (now.difference(session.created) > ttl ||
        now.difference(session.lastSeen) > idleTimeout) {
      end(session);
      return false;
    }
    return true;
  }

  /// Ends one session.
  void end(LoginSession session) {
    if (_byHash.remove(session.tokenHash) != null) onEnded?.call(session);
  }

  /// Ends the session with public [id]. Returns false if unknown.
  bool revoke(String id) {
    for (final s in _byHash.values.toList()) {
      if (s.id == id) {
        end(s);
        return true;
      }
    }
    return false;
  }

  /// Ends every session ("log out everywhere").
  int endAll() {
    final all = _byHash.values.toList();
    all.forEach(end);
    return all.length;
  }

  /// Active sessions, newest first.
  List<LoginSession> list() {
    sweep();
    return _byHash.values.toList()
      ..sort((a, b) => b.created.compareTo(a.created));
  }

  /// Drops expired sessions.
  void sweep() {
    final now = _clock();
    for (final s in _byHash.values.toList()) {
      if (now.difference(s.created) > ttl ||
          now.difference(s.lastSeen) > idleTimeout) {
        end(s);
      }
    }
  }
}
