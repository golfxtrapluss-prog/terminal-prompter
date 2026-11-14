import 'dart:convert';
import 'dart:typed_data';

/// A web client file compiled into the agent binary.
///
/// Generated into `lib/src/generated/assets.g.dart` by
/// `tool/embed_assets.dart`. Content is stored gzip-compressed as base64 text
/// so the generated source stays compact and fully `const`. Decoding happens on
/// demand; the HTTP layer caches decoded bytes per process.
final class EmbeddedAsset {
  /// Creates an asset. [gzipBase64] is the gzip-compressed content, base64
  /// encoded.
  const EmbeddedAsset({
    required this.path,
    required this.contentType,
    required this.etag,
    required this.rawLength,
    required String gzipBase64,
  }) : _gzipBase64 = gzipBase64;

  /// URL path relative to the web root, without a leading slash.
  final String path;

  /// Value for the `Content-Type` response header.
  final String contentType;

  /// Strong ETag (hex SHA-256 prefix of the uncompressed content), unquoted.
  final String etag;

  /// Size of the uncompressed content in bytes.
  final int rawLength;

  final String _gzipBase64;

  /// The gzip-compressed content, ready to send with
  /// `Content-Encoding: gzip`.
  Uint8List get gzipBytes => base64Decode(_gzipBase64);
}
