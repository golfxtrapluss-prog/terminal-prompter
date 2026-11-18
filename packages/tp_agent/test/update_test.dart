import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tp_agent/src/update/release.dart';

void main() {
  late Directory dir;
  late HttpServer server;
  late List<int> seed;
  late String publicKey;
  final binary = utf8.encode('#!/bin/sh\necho new-version\n');

  Future<void> publish({
    String version = '1.2.3',
    List<int>? servedBinary,
    List<int>? signSeed,
    bool tamperSums = false,
  }) async {
    final rel = Directory('${dir.path}/rel')..createSync(recursive: true);
    File(
      '${rel.path}/tp-agent-linux-x64',
    ).writeAsBytesSync(servedBinary ?? binary);
    var manifest = buildManifest(version, {'tp-agent-linux-x64': binary});
    final sig = await signEd25519(utf8.encode(manifest), signSeed ?? seed);
    if (tamperSums) {
      manifest = manifest.replaceFirst('# version $version', '# version 9.9.9');
    }
    File('${rel.path}/SHA256SUMS').writeAsStringSync(manifest);
    File('${rel.path}/SHA256SUMS.sig').writeAsStringSync(sig);
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('tp_update_');
    seed = newSigningSeed();
    publicKey = await publicKeyForSeed(seed);
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final f = File('${dir.path}/rel${req.uri.path}');
      if (f.existsSync()) {
        req.response.add(f.readAsBytesSync());
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
    File('${dir.path}/tp-agent').writeAsStringSync('old binary');
  });

  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  Updater updater({
    String? key,
    String current = '1.0.0',
    String scheme = 'http',
    String host = '127.0.0.1',
  }) => Updater(
    baseUrl: Uri.parse('$scheme://$host:${server.port}/'),
    publicKey: key ?? publicKey,
    currentVersion: current,
    target: '${dir.path}/tp-agent',
    asset: 'tp-agent-linux-x64',
  );

  String target() => File('${dir.path}/tp-agent').readAsStringSync();

  test('valid signed release is installed atomically and executable', () async {
    await publish();
    final u = updater();
    final r = await u.run();
    u.close();
    expect(r.installed, isTrue);
    expect(r.version, '1.2.3');
    expect(target(), utf8.decode(binary));
    expect(
      Process.runSync('stat', [
        '-c',
        '%a',
        '${dir.path}/tp-agent',
      ]).stdout.toString().trim(),
      '755',
    );
    expect(dir.listSync().where((e) => e.path.contains('.new-')), isEmpty);
  });

  test('check-only and same version do not install', () async {
    await publish(version: '1.0.0');
    final u = updater();
    expect((await u.run()).installed, isFalse, reason: 'already 1.0.0');
    await publish(version: '2.0.0');
    final r = await u.run(checkOnly: true);
    u.close();
    expect(r.installed, isFalse);
    expect(r.version, '2.0.0');
    expect(target(), 'old binary');
  });

  test(
    'refuses: wrong key, tampered SHA256SUMS, swapped binary, no key, plain http to a remote host',
    () async {
      await publish(signSeed: newSigningSeed());
      await expectLater(
        updater().run(),
        throwsA(
          isA<UpdateError>().having(
            (e) => e.message,
            'm',
            contains('signature'),
          ),
        ),
      );

      await publish(tamperSums: true);
      await expectLater(
        updater().run(),
        throwsA(
          isA<UpdateError>().having(
            (e) => e.message,
            'm',
            contains('signature'),
          ),
        ),
      );

      await publish(servedBinary: utf8.encode('evil'));
      await expectLater(
        updater().run(),
        throwsA(
          isA<UpdateError>().having((e) => e.message, 'm', contains('SHA-256')),
        ),
      );

      await publish();
      await expectLater(
        updater(key: '').run(),
        throwsA(
          isA<UpdateError>().having(
            (e) => e.message,
            'm',
            contains('no release key'),
          ),
        ),
      );
      await expectLater(
        updater(host: 'example.com').run(),
        throwsA(
          isA<UpdateError>().having((e) => e.message, 'm', contains('https')),
        ),
      );
      expect(target(), 'old binary', reason: 'nothing was replaced');
    },
  );

  test('manifest parsing', () {
    final m = ReleaseManifest.parse(
      '# version 1.0.0\n${'a' * 64}  tp-agent-linux-x64\n${'b' * 64} *tp-agent-linux-arm64\n',
    );
    expect(m.version, '1.0.0');
    expect(m.sums.keys, ['tp-agent-linux-x64', 'tp-agent-linux-arm64']);
    expect(
      () => ReleaseManifest.parse('${'a' * 64}  x\n'),
      throwsA(isA<UpdateError>()),
    );
    expect(
      () => ReleaseManifest.parse('# version 1\nnot a line\n'),
      throwsA(isA<UpdateError>()),
    );
  });

  test(
    'signing tool output verifies with the matching public key only',
    () async {
      final msg = utf8.encode('hello');
      final sig = base64Decode(await signEd25519(msg, seed));
      expect(await verifyEd25519(msg, sig, base64Decode(publicKey)), isTrue);
      expect(
        await verifyEd25519(utf8.encode('hellp'), sig, base64Decode(publicKey)),
        isFalse,
      );
      expect(
        await verifyEd25519(
          msg,
          sig,
          base64Decode(await publicKeyForSeed(newSigningSeed())),
        ),
        isFalse,
      );
    },
  );
}
