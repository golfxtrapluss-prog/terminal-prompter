import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

import '../config/config.dart';
import '../session/session_manager.dart';
import '../transport/client_connection.dart';
import '../transport/ws_transport.dart';
import 'security_headers.dart';
import 'static_files.dart';

/// The agent's HTTP server: static client, `/healthz`, `/api/ws` (docs/02).
final class AgentServer {
  /// Creates the server. [port] overrides `config.listenPort` (tests use 0).
  AgentServer({
    required this.config,
    required this.sessions,
    required this.staticFiles,
    required this.agentVersion,
    int? port,
  }) : _port = port ?? config.listenPort;

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
        if (path == 'api/ws' &&
            WebSocketTransformer.isUpgradeRequest(request)) {
          await _upgrade(request);
          return;
        }
        await _notFound(response);
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
    final connection = ClientConnection(
      transport: WsTransport(socket, peer: peer),
      sessions: sessions,
      agentVersion: agentVersion,
      host: Platform.localHostname,
    );
    final future = connection.run();
    _connections[connection] = future;
    unawaited(future.whenComplete(() => _connections.remove(connection)));
  }

  Future<void> _notFound(HttpResponse response) async {
    response.statusCode = HttpStatus.notFound;
    response.headers.contentType = ContentType.text;
    response.write('not found');
    await response.close();
  }
}
