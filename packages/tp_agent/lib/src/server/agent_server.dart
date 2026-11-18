import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:tp_protocol/tp_protocol.dart';

import '../audit/audit_log.dart';
import '../auth/auth_service.dart';
import '../auth/login_sessions.dart';
import '../config/config.dart';
import '../session/session_manager.dart';
import '../transport/client_connection.dart';
import '../transport/ws_transport.dart';
import 'api.dart';
import 'security_headers.dart';
import 'static_files.dart';

/// The agent's HTTP server: static client, `/healthz`, the JSON API and
/// `/api/ws` (docs/02).
///
/// Every API call and WebSocket needs a login from [auth]. Passing
/// `auth: null` turns authentication off; that exists only for tests and is
/// never reachable from the CLI (`tp-agent run` refuses to start without a
/// password).
final class AgentServer {
  /// Creates the server. [port] overrides `config.listenPort` (tests use 0).
  AgentServer({
    required this.config,
    required this.sessions,
    required this.staticFiles,
    required this.agentVersion,
    required this.auth,
    AuditLog? audit,
    int? port,
  }) : _port = port ?? config.listenPort,
       audit = audit ?? AuditLog.disabled(),
       guard = RequestGuard(config) {
    final a = auth;
    if (a != null) {
      api = Api(
        config: config,
        auth: a,
        sessions: sessions,
        guard: guard,
        agentVersion: agentVersion,
      );
      // Close the WebSockets of a login the moment it ends.
      a.sessions.onEnded = (login) {
        for (final c
            in _connections.keys
                .where((c) => _loginOf[c] == login.tokenHash)
                .toList()) {
          unawaited(c.transport.close(code: 4401, reason: 'logged out'));
        }
      };
    }
  }

  /// Authentication; null only in tests.
  final AuthService? auth;

  /// Audit log.
  final AuditLog audit;

  /// Origin/IP helpers.
  final RequestGuard guard;

  /// JSON API (null when [auth] is null).
  Api? api;

  /// Agent configuration.
  final AgentConfig config;

  /// Session registry.
  final SessionManager sessions;

  /// Client files.
  final StaticFiles staticFiles;

  /// Agent build identifier.
  final String agentVersion;

  final int _port;
  final Logger _log = Logger('server');
  HttpServer? _server;
  final Map<ClientConnection, Future<void>> _connections = {};
  final Map<ClientConnection, String> _loginOf = {};
  Timer? _sweeper;

  /// Port actually bound (differs from the configured one only for port 0).
  int get port => _server?.port ?? _port;

  /// Binds and starts serving.
  Future<void> start() async {
    final host = config.listenHost;
    final tls = config.tls;
    final HttpServer server;
    if (config.mode == AgentMode.standalone && tls != null) {
      final context = SecurityContext()
        ..useCertificateChain(tls.certFile)
        ..usePrivateKey(tls.keyFile);
      server = await HttpServer.bindSecure(host, _port, context);
    } else {
      server = await HttpServer.bind(host, _port);
    }
    server.serverHeader = null;
    _server = server;
    server.listen(
      _handle,
      onError: (Object e, StackTrace st) {
        _log.warning({'msg': 'accept_error'}, e, st);
      },
    );
    _sweeper = Timer.periodic(
      const Duration(minutes: 1),
      (_) => auth?.sessions.sweep(),
    );
    if (auth == null) {
      _log.warning({'msg': 'auth_disabled', 'hint': 'tests only'});
    }
    _log.info({
      'msg': 'listening',
      'host': host,
      'port': server.port,
      'mode': config.mode.name,
      'base_path': config.basePath,
      'version': agentVersion,
    });
  }

  /// Stops accepting requests and closes open connections. Upgraded
  /// WebSockets are detached from the HttpServer, so they are closed here
  /// explicitly.
  Future<void> stop() async {
    _sweeper?.cancel();
    await _server?.close(force: true);
    _server = null;
    for (final connection in _connections.keys.toList()) {
      await connection.transport.close(code: 1001, reason: 'agent stopping');
    }
    await Future.wait(
      _connections.values.toList(),
    ).timeout(const Duration(seconds: 5), onTimeout: () => const []);
    _connections.clear();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    applySecurityHeaders(response, hsts: config.mode == AgentMode.standalone);
    try {
      final fullPath = request.uri.path;
      final base = config.basePath;
      if (fullPath != base.substring(0, base.length - 1) &&
          !fullPath.startsWith(base)) {
        await _notFound(response);
        return;
      }
      final path = fullPath.length >= base.length
          ? fullPath.substring(base.length)
          : '';
      if (path == 'healthz') {
        response.headers.contentType = ContentType.text;
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        response.write('ok');
        await response.close();
        return;
      }
      if (path.startsWith('api/')) {
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        if (path == 'api/ws') {
          if (!WebSocketTransformer.isUpgradeRequest(request)) {
            await _status(
              response,
              HttpStatus.badRequest,
              'websocket upgrade required',
            );
            return;
          }
          await _upgrade(request);
          return;
        }
        final a = api;
        if (a == null) {
          await _notFound(response);
          return;
        }
        await a.handle(request, path.substring(4));
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }
      await staticFiles.serve(request, path);
    } on Object catch (e, st) {
      _log.warning({'msg': 'request_error', 'path': request.uri.path}, e, st);
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } on Object {
        // Response already committed; nothing more to do.
      }
    }
  }

  Future<void> _upgrade(HttpRequest request) async {
    // Cross-site WebSocket hijacking: browsers always send Origin, and it
    // must be ours (docs/05).
    if (guard.allowedOrigin(request) == null && auth != null) {
      await _status(request.response, HttpStatus.forbidden, 'bad origin');
      return;
    }
    LoginSession? login;
    final a = api;
    if (a != null) {
      login = a.currentLogin(request);
      if (login == null) {
        await _status(
          request.response,
          HttpStatus.unauthorized,
          'auth required',
        );
        return;
      }
      final open = _loginOf.values.where((h) => h == login!.tokenHash).length;
      if (open >= Limits.maxWebSocketsPerLogin) {
        await _status(
          request.response,
          HttpStatus.tooManyRequests,
          'too many connections',
        );
        return;
      }
    }
    final socket = await WebSocketTransformer.upgrade(
      request,
      compression: config.transport.compression
          ? CompressionOptions.compressionDefault
          : CompressionOptions.compressionOff,
    );
    // Protocol-level pings keep proxies from cutting idle connections and
    // detect dead peers (docs/07); browsers answer pong frames automatically.
    socket.pingInterval = config.transport.heartbeat;
    final info = request.connectionInfo;
    final peer = info == null
        ? 'unknown'
        : '${info.remoteAddress.address}:${info.remotePort}';
    final ip = guard.clientIp(request);
    final connection = ClientConnection(
      transport: WsTransport(socket, peer: peer),
      sessions: sessions,
      agentVersion: agentVersion,
      host: Platform.localHostname,
      audit: audit,
      clientIp: ip,
      logInput: config.audit.logInput,
      // Keep the login's idle timer fresh while the terminal is in use, and
      // drop the connection if the login has meanwhile expired.
      onActivity: login == null ? null : () => _stillValid(login!),
    );
    final future = connection.run();
    _connections[connection] = future;
    if (login != null) _loginOf[connection] = login.tokenHash;
    unawaited(
      future.whenComplete(() {
        _connections.remove(connection);
        _loginOf.remove(connection);
      }),
    );
  }

  /// True while [login] is still active; refreshes its idle timer.
  bool _stillValid(LoginSession login) {
    final a = auth!;
    if (!a.sessions.isActive(login)) return false;
    login.lastSeen = DateTime.now();
    return true;
  }

  Future<void> _status(HttpResponse response, int status, String text) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.text;
    response.write(text);
    await response.close();
  }

  Future<void> _notFound(HttpResponse response) async {
    response.statusCode = HttpStatus.notFound;
    response.headers.contentType = ContentType.text;
    response.write('not found');
    await response.close();
  }
}
