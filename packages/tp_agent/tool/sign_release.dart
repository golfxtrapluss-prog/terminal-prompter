/// Writes `SHA256SUMS` (with `# version`) and `SHA256SUMS.sig` for the files
/// in a release directory.
///
/// Usage: `TP_RELEASE_SIGNING_KEY=<base64 seed> dart run tool/sign_release.dart <dir> <version>`
library;

import 'dart:convert';
import 'dart:io';

import 'package:tp_agent/src/update/release.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/sign_release.dart <dir> <version>');
    exitCode = 64;
    return;
  }
  final seedB64 = Platform.environment['TP_RELEASE_SIGNING_KEY'];
  if (seedB64 == null || seedB64.isEmpty) {
    stderr.writeln('TP_RELEASE_SIGNING_KEY is not set');
    exitCode = 64;
    return;
  }
  final dir = Directory(args[0]);
  final files = <String, List<int>>{};
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (name.startsWith('tp-agent-')) files[name] = f.readAsBytesSync();
  }
  if (files.isEmpty) {
    stderr.writeln('no tp-agent-* files in ${dir.path}');
    exitCode = 66;
    return;
  }
  final manifest = buildManifest(args[1], files);
  final sig = await signEd25519(utf8.encode(manifest), base64Decode(seedB64));
  File('${dir.path}/SHA256SUMS').writeAsStringSync(manifest);
  File('${dir.path}/SHA256SUMS.sig').writeAsStringSync('$sig\n');
  stdout
    ..write(manifest)
    ..writeln('signed with ${await publicKeyForSeed(base64Decode(seedB64))}');
}
