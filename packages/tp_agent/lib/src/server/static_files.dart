import 'dart:io';

import 'package:path/path.dart' as p;

import '../assets/content_types.dart';
import '../assets/embedded_asset.dart';

/// Serves the web client.
abstract interface class StaticFiles {
  /// Writes the file for [path] (no leading slash, `''` for the index) to
  /// [request]'s response and closes it. Unknown paths get 404.
  Future<void> serve(HttpRequest request, String path);
}

/// Serves files compiled into the binary (gzip + ETag).
final class EmbeddedStaticFiles implements StaticFiles {
  /// Serves [assets] keyed by path.
  EmbeddedStaticFiles(this.assets);

  /// The embedded files.
  final Map<String, EmbeddedAsset> assets;
  final Map<String, List<int>> _rawCache = {};

  @override
  Future<void> serve(HttpRequest request, String path) async {
    final asset = assets[path.isEmpty ? 'index.html' : path];
    final response = request.response;
    if (asset == null) {
      response.statusCode = HttpStatus.notFound;
      response.headers.contentType = ContentType.text;
      response.write('not found');
      await response.close();
      return;
    }
    final etag = '"${asset.etag}"';
    response.headers
      ..set(HttpHeaders.etagHeader, etag)
      ..set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..set(HttpHeaders.varyHeader, 'Accept-Encoding');
    if (request.headers.value(HttpHeaders.ifNoneMatchHeader) == etag) {
      response.statusCode = HttpStatus.notModified;
      await response.close();
      return;
    }
    response.headers.set(HttpHeaders.contentTypeHeader, asset.contentType);
    final acceptsGzip =
        request.headers[HttpHeaders.acceptEncodingHeader]
            ?.join(',')
            .contains('gzip') ??
        false;
    if (acceptsGzip) {
      final bytes = asset.gzipBytes;
      response.headers
        ..set(HttpHeaders.contentEncodingHeader, 'gzip')
        ..contentLength = bytes.length;
      response.add(bytes);
    } else {
      final bytes = _rawCache[asset.path] ??= gzip.decode(asset.gzipBytes);
      response.headers.contentLength = bytes.length;
      response.add(bytes);
    }
    await response.close();
  }
}

/// Serves files from a directory on disk (development only, `--dev-web-dir`).
final class DirectoryStaticFiles implements StaticFiles {
  /// Serves files under [directory].
  DirectoryStaticFiles(String directory) : _root = p.canonicalize(directory);

  final String _root;

  @override
  Future<void> serve(HttpRequest request, String path) async {
    final response = request.response;
    final candidate = p.canonicalize(
      p.join(_root, path.isEmpty ? 'index.html' : path),
    );
    final file = File(candidate);
    if (!p.isWithin(_root, candidate) || !file.existsSync()) {
      response.statusCode = HttpStatus.notFound;
      response.headers.contentType = ContentType.text;
      response.write('not found');
      await response.close();
      return;
    }
    final bytes = await file.readAsBytes();
    response.headers
      ..set(HttpHeaders.contentTypeHeader, contentTypeForPath(candidate))
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }
}
