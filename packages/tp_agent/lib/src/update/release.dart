import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import '../auth/encoding.dart';
import '../log_util.dart' show restrictToOwner;

/// Base64 ed25519 public key that release `SHA256SUMS` files must be signed
/// with. Baked in at build time (`make build TP_RELEASE_KEY=...`); a build
/// without it refuses to self-update (docs/05 "Kompromittert oppdatering").
const String releasePublicKey = String.fromEnvironment('TP_RELEASE_KEY');

/// Default release download base URL, baked in at build time.
const String defaultReleaseUrl = String.fromEnvironment('TP_RELEASE_URL');

/// Why an update was refused.
final class UpdateError implements Exception {
  const UpdateError(this.message);

  final String message;

  @override
  String toString() => 'UpdateError: $message';
}

/// Parsed `SHA256SUMS`: `<hex>  <file>` lines plus `# version <v>`.
final class ReleaseManifest {
  ReleaseManifest._(this.version, this.sums);

  factory ReleaseManifest.parse(String text) {
    String? version;
    final sums = <String, String>{};
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        final m = RegExp(r'^#\s*version\s+(\S+)$').firstMatch(line);
        if (m != null) version = m.group(1);
        continue;
      }
      final m = RegExp(r'^([0-9a-f]{64})\s+\*?(\S+)$').firstMatch(line);
      if (m == null) throw UpdateError('bad SHA256SUMS line: $line');
      sums[m.group(2)!] = m.group(1)!;
    }
    if (version == null) {
      throw const UpdateError('SHA256SUMS has no "# version" line');
    }
    return ReleaseManifest._(version, sums);
  }

  final String version;

  /// File name → lowercase hex SHA-256.
  final Map<String, String> sums;
}

/// Verifies an ed25519 [signature] of [message] with [publicKey] (raw
/// 32-byte keys, raw 64-byte signatures).
Future<bool> verifyEd25519(
  List<int> message,
  List<int> signature,
  List<int> publicKey,
) async {
  if (publicKey.length != 32 || signature.length != 64) return false;
  return Ed25519().verify(
    message,
    signature: Signature(
      signature,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
    ),
  );
}

/// Name of the release asset for this machine.
String assetForThisMachine() {
  final abi = Abi.current();
  if (abi == Abi.linuxX64) return 'tp-agent-linux-x64';
  if (abi == Abi.linuxArm64) return 'tp-agent-linux-arm64';
  throw UpdateError('no release for $abi');
}

/// Result of [Updater.run].
final class UpdateResult {
  const UpdateResult({
    required this.version,
    required this.installed,
    required this.path,
  });

  final String version;

  /// False when already up to date or in check-only mode.
  final bool installed;
  final String path;
}

/// Downloads, verifies and atomically installs a release (docs/02
/// `tp-agent selfupdate`). The order matters: the signature over
/// `SHA256SUMS` is checked before any hash in it is trusted, and the binary
/// is only renamed into place after its SHA-256 matches.
final class Updater {
  Updater({
    required this.baseUrl,
    required this.publicKey,
    required this.currentVersion,
    required this.target,
    String? asset,
    HttpClient? client,
  }) : asset = asset ?? assetForThisMachine(),
       _http = client ?? HttpClient();

  static const int maxManifestBytes = 64 * 1024;
  static const int maxBinaryBytes = 200 * 1024 * 1024;

  /// Base URL ending in `/`, e.g. `https://github.com/o/r/releases/latest/download/`.
  final Uri baseUrl;
  final String publicKey;
  final String currentVersion;

  /// Binary to replace.
  final String target;
  final String asset;
  final HttpClient _http;

  Future<UpdateResult> run({bool checkOnly = false, bool force = false}) async {
    if (publicKey.isEmpty) {
      throw const UpdateError(
        'this build has no release key; self-update is disabled',
      );
    }
    final key = _decodeKey(publicKey);
    _requireSecure(baseUrl);
    final sums = await _download(
      baseUrl.resolve('SHA256SUMS'),
      maxManifestBytes,
    );
    final sigText = utf8
        .decode(await _download(baseUrl.resolve('SHA256SUMS.sig'), 1024))
        .trim();
    final List<int> sig;
    try {
      sig = base64Decode(sigText);
    } on FormatException {
      throw const UpdateError('SHA256SUMS.sig is not base64');
    }
    if (!await verifyEd25519(sums, sig, key)) {
      throw const UpdateError(
        'SHA256SUMS signature does not verify; refusing to update',
      );
    }
    final manifest = ReleaseManifest.parse(utf8.decode(sums));
    final expected =
        manifest.sums[asset] ?? (throw UpdateError('release has no $asset'));
    if (checkOnly || (!force && manifest.version == currentVersion)) {
      return UpdateResult(
        version: manifest.version,
        installed: false,
        path: target,
      );
    }
    final tmp = '$target.new-$pid';
    try {
      final digest = await _downloadTo(baseUrl.resolve(asset), tmp);
      if (digest != expected) {
        throw const UpdateError('binary SHA-256 does not match SHA256SUMS');
      }
      final chmod = Process.runSync('chmod', ['755', tmp]);
      if (chmod.exitCode != 0) {
        throw UpdateError('chmod failed: ${chmod.stderr}');
      }
      File(tmp).renameSync(target);
    } finally {
      final f = File(tmp);
      if (f.existsSync()) f.deleteSync();
    }
    return UpdateResult(
      version: manifest.version,
      installed: true,
      path: target,
    );
  }

  void close() => _http.close(force: true);

  static List<int> _decodeKey(String b64) {
    try {
      final key = base64Decode(b64);
      if (key.length != 32) throw const FormatException();
      return key;
    } on FormatException {
      throw const UpdateError('invalid release key in this build');
    }
  }

  static void _requireSecure(Uri url) {
    final loopback =
        InternetAddress.tryParse(url.host)?.isLoopback ??
        url.host == 'localhost';
    if (url.scheme != 'https' && !(url.scheme == 'http' && loopback)) {
      throw const UpdateError('release URL must use https');
    }
  }

  Future<Uint8List> _download(Uri url, int limit) async {
    final res = await (await _http.getUrl(url)).close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw UpdateError('GET $url: HTTP ${res.statusCode}');
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in res) {
      out.add(chunk);
      if (out.length > limit) throw UpdateError('$url is larger than expected');
    }
    return out.takeBytes();
  }

  Future<String> _downloadTo(Uri url, String path) async {
    final res = await (await _http.getUrl(url)).close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw UpdateError('GET $url: HTTP ${res.statusCode}');
    }
    final sink = File(path).openWrite();
    final hashSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(hashSink);
    var size = 0;
    try {
      await for (final chunk in res) {
        size += chunk.length;
        if (size > maxBinaryBytes) {
          throw const UpdateError('binary larger than expected');
        }
        hasher.add(chunk);
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    hasher.close();
    restrictToOwner(path);
    return hashSink.value.toString();
  }
}

final class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Creates `SHA256SUMS` text for release files (used by tool/sign_release.dart).
String buildManifest(String version, Map<String, List<int>> files) {
  final b = StringBuffer('# version $version\n');
  for (final name in files.keys.toList()..sort()) {
    b.writeln('${sha256.convert(files[name]!)}  $name');
  }
  return b.toString();
}

/// Ed25519 signature of [message] with a 32-byte [seed], base64.
Future<String> signEd25519(List<int> message, List<int> seed) async {
  final algorithm = Ed25519();
  final pair = await algorithm.newKeyPairFromSeed(seed);
  final sig = await algorithm.sign(message, keyPair: pair);
  return base64Encode(sig.bytes);
}

/// Public key (base64) for a 32-byte [seed].
Future<String> publicKeyForSeed(List<int> seed) async {
  final pair = await Ed25519().newKeyPairFromSeed(seed);
  final pub = await pair.extractPublicKey();
  return base64Encode(pub.bytes);
}

/// A fresh random 32-byte seed (private key).
List<int> newSigningSeed() => randomBytes(32);
