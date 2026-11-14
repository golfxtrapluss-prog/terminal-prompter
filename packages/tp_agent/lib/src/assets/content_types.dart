/// `Content-Type` values by file extension for the embedded web client.
const Map<String, String> contentTypesByExtension = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json',
  '.map': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
  '.wasm': 'application/wasm',
};

/// Returns the `Content-Type` for [path] based on its extension.
String contentTypeForPath(String path) {
  final dot = path.lastIndexOf('.');
  final slash = path.lastIndexOf('/');
  if (dot < 0 || dot < slash) return 'application/octet-stream';
  return contentTypesByExtension[path.substring(dot).toLowerCase()] ??
      'application/octet-stream';
}
