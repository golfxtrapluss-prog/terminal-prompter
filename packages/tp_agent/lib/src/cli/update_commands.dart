import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';

import '../config/config.dart';
import '../update/release.dart';
import '../version.dart';

/// `tp-agent selfupdate`: download, verify (ed25519 + SHA-256) and swap the
/// binary atomically (docs/02).
final class SelfUpdateCommand extends Command<int> {
  SelfUpdateCommand({required this.out, required this.err}) {
    argParser
      ..addOption('config', abbr: 'c', defaultsTo: '/etc/tp-agent/config.toml')
      ..addOption('url', help: 'Release base URL (overrides [update] url).')
      ..addFlag(
        'check',
        negatable: false,
        help: 'Only report the available version.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Install even if the version is the same.',
      )
      ..addFlag(
        'restart',
        negatable: false,
        help: 'Run "systemctl restart tp-agent" afterwards.',
      );
  }

  final StringSink out;
  final StringSink err;

  @override
  String get name => 'selfupdate';

  @override
  String get description => 'Update this binary from a signed release.';

  @override
  Future<int> run() async {
    final args = argResults!;
    var url = args.option('url');
    if (url == null) {
      final path = args.option('config')!;
      if (File(path).existsSync()) {
        try {
          url = (await AgentConfig.load(path)).update.url;
        } on ConfigError catch (e) {
          err.writeln('tp-agent: $e');
          return 78;
        }
      }
    }
    url ??= defaultReleaseUrl;
    if (url.isEmpty) {
      err.writeln(
        'No release URL: set [update] url in the config or pass --url.',
      );
      return 64;
    }
    final updater = Updater(
      baseUrl: Uri.parse(url.endsWith('/') ? url : '$url/'),
      publicKey: releasePublicKey,
      currentVersion: tpVersion,
      target: Platform.resolvedExecutable,
    );
    try {
      final result = await updater.run(
        checkOnly: args.flag('check'),
        force: args.flag('force'),
      );
      if (!result.installed) {
        out.writeln(
          result.version == tpVersion
              ? 'Up to date ($tpVersion).'
              : 'Available: ${result.version} (installed: $tpVersion). Run without --check to update.',
        );
        return 0;
      }
      out.writeln(
        'Updated ${result.path} to ${result.version} (signature and SHA-256 verified).',
      );
      if (args.flag('restart')) {
        final r = Process.runSync('systemctl', ['restart', 'tp-agent']);
        if (r.exitCode != 0) {
          err.writeln('systemctl restart failed: ${r.stderr}');
          return 1;
        }
        out.writeln('Restarted tp-agent.');
      } else {
        out.writeln('Restart to use it: sudo systemctl restart tp-agent');
      }
      return 0;
    } on UpdateError catch (e) {
      err.writeln('tp-agent: ${e.message}');
      return 1;
    } on IOException catch (e) {
      err.writeln('tp-agent: download failed: $e');
      return 1;
    } finally {
      updater.close();
    }
  }
}

/// `tp-agent verify`: checks a release's SHA256SUMS signature with this
/// binary's built-in key, and optionally a file against it. Meaningful when
/// run by an already trusted binary (a binary cannot vouch for itself).
final class VerifyCommand extends Command<int> {
  VerifyCommand({required this.out, required this.err}) {
    argParser
      ..addOption('sums', mandatory: true, help: 'Path to SHA256SUMS.')
      ..addOption('sig', mandatory: true, help: 'Path to SHA256SUMS.sig.');
  }

  final StringSink out;
  final StringSink err;

  @override
  String get name => 'verify';

  @override
  String get description =>
      'Verify a release signature (and files listed in it).';

  @override
  String get invocation =>
      'tp-agent verify --sums SHA256SUMS --sig SHA256SUMS.sig [file ...]';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (releasePublicKey.isEmpty) {
      err.writeln('This build has no release key.');
      return 1;
    }
    final sums = File(args.option('sums')!).readAsBytesSync();
    final sig = File(args.option('sig')!).readAsStringSync().trim();
    final ok = await verifyEd25519(
      sums,
      base64Decode(sig),
      base64Decode(releasePublicKey),
    );
    if (!ok) {
      err.writeln('Signature does NOT verify.');
      return 1;
    }
    final manifest = ReleaseManifest.parse(String.fromCharCodes(sums));
    out.writeln('Signature OK: release ${manifest.version}.');
    for (final path in args.rest) {
      final name = path.split('/').last;
      final expected = manifest.sums[name];
      final actual = sha256OfFile(path);
      if (expected == null || expected != actual) {
        err.writeln('$name: MISMATCH');
        return 1;
      }
      out.writeln('$name: OK');
    }
    return 0;
  }
}

/// Hex SHA-256 of a file.
String sha256OfFile(String path) =>
    sha256.convert(File(path).readAsBytesSync()).toString();
