import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Error answer from the agent's JSON API.
final class ApiException implements Exception {
  const ApiException(this.status, this.code, {this.retryAfter});

  final int status;
  final String code;

  /// Seconds from the `Retry-After` header, when present.
  final int? retryAfter;

  @override
  String toString() => 'ApiException($status, $code)';
}

/// Same-origin JSON client for `<base>/api/…`. Sends the CSRF token from
/// the `tp_csrf` cookie as `X-TP-CSRF` on every POST (docs/05).
final class ApiClient {
  ApiClient(this.base);

  /// Base path ending in `/`, e.g. `/` or `/tp-9f3k2/`.
  final String base;

  Future<Map<String, Object?>> get(String path) => _send('GET', path, null);

  Future<Map<String, Object?>> post(
    String path, [
    Map<String, Object?> body = const {},
  ]) => _send('POST', path, body);

  static String? csrfToken() {
    for (final part in web.document.cookie.split(';')) {
      final kv = part.trim();
      if (kv.startsWith('tp_csrf=')) return kv.substring(8);
    }
    return null;
  }

  Future<Map<String, Object?>> _send(
    String method,
    String path,
    Map<String, Object?>? body,
  ) async {
    final headers = web.Headers();
    if (body != null) {
      headers.set('Content-Type', 'application/json');
      final csrf = csrfToken();
      if (csrf != null) headers.set('X-TP-CSRF', csrf);
    }
    final init = web.RequestInit(
      method: method,
      headers: headers,
      credentials: 'same-origin',
      cache: 'no-store',
    );
    if (body != null) init.body = jsonEncode(body).toJS;
    final web.Response response;
    try {
      response = await web.window.fetch('${base}api/$path'.toJS, init).toDart;
    } on Object {
      throw const ApiException(0, 'network');
    }
    final text = (await response.text().toDart).toDart;
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      json = null;
    }
    if (!response.ok) {
      final code = json is Map<String, Object?> && json['error'] is String
          ? json['error']! as String
          : 'http_${response.status}';
      final retry = int.tryParse(response.headers.get('Retry-After') ?? '');
      throw ApiException(response.status, code, retryAfter: retry);
    }
    return json is Map<String, Object?> ? json : const {};
  }
}
