@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tp_agent/tp_agent.dart';

/// Collects terminal output as text and lets tests wait for patterns.
final class OutputCollector {
  OutputCollector(Stream<Uint8List> stream) {
    _subscription = stream.listen(
      (chunk) => _buf.write(latin1.decode(chunk)),
      onDone: _done.complete,
    );
  }

  final StringBuffer _buf = StringBuffer();
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<Uint8List> _subscription;

  String get text => _buf.toString();
  bool get isDone => _done.isCompleted;
  Future<void> get done => _done.future;

  Future<String> waitFor(
    Pattern pattern, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final sw = Stopwatch()..start();
    while (!text.contains(pattern)) {
      if (isDone) {
        throw StateError('output closed before "$pattern". Output:\n$text');
      }
      if (sw.elapsed > timeout) {
        throw TimeoutException('no "$pattern" in output:\n$text');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return text;
  }

  Future<void> cancel() => _subscription.cancel();
}

const prompt = r'TP$ ';

Future<PtyProcess> startBash({int cols = 80, int rows = 24}) {
  return PtyProcess.start(
    command: '/bin/bash',
    arguments: const ['--norc', '--noprofile', '-i'],
    environment: const {
      'TERM': 'xterm-256color',
      'PS1': prompt,
      'LANG': 'C.UTF-8',
    },
    cols: cols,
    rows: rows,
  );
}

Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String what = 'condition',
}) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > timeout) {
      throw TimeoutException('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  final onLinux = Platform.isLinux;

  group('PtyProcess', () {
    late PtyProcess pty;
    late OutputCollector out;

    setUp(() async {
      pty = await startBash();
      out = OutputCollector(pty.output);
      await out.waitFor(prompt);
    });

    tearDown(() async {
      if (pty.sessionPids().isNotEmpty) {
        await pty.terminate(grace: const Duration(milliseconds: 500));
      }
      await pty.close();
      await out.cancel();
    });

    test('runs a command and reports the exit code', () async {
      await pty.write(utf8.encode("printf 'tp-%s\\n' ok\r"));
      await out.waitFor('tp-ok');

      await pty.write(utf8.encode('exit 7\r'));
      final info = await pty.exited;
      expect(info.code, 7);
      expect(info.signal, isNull);
      await out.done; // slave closed -> EIO -> stream ends
    });

    test(
      'child is session leader with the PTY as controlling terminal',
      () async {
        final stat = PtyProcess.readProcStat(pty.pid)!;
        expect(stat.sid, pty.pid, reason: 'setsid must not fork (sid == pid)');
        expect(stat.pgid, pty.pid);
        expect(stat.ttyNr, isNot(0), reason: 'no controlling terminal');

        await pty.write(utf8.encode('tty\r'));
        await out.waitFor('/dev/pts/');
        expect(out.text, contains(pty.ptsPath));
      },
    );

    test('resize is visible to the shell via stty size', () async {
      await pty.write(utf8.encode('stty size\r'));
      await out.waitFor('24 80');

      pty.resize(100, 40);
      expect(pty.cols, 100);
      expect(pty.rows, 40);
      await pty.write(utf8.encode('stty size\r'));
      await out.waitFor('40 100');
    });

    test('Ctrl-C interrupts the foreground job', () async {
      await pty.write(utf8.encode('sleep 100\r'));
      await waitUntil(() => pty.sessionPids().length >= 2, what: 'sleep');

      await pty.write([0x03]);
      await pty.write(utf8.encode('echo rc=\$?\r'));
      await out.waitFor('rc=130');
      expect(pty.sessionPids(), [pty.pid], reason: 'sleep should be gone');
    });

    test('terminate kills background jobs so no orphans remain', () async {
      await pty.write(utf8.encode('sleep 1000 &\r'));
      await pty.write(utf8.encode('sleep 1000 | sleep 1000 &\r'));
      await waitUntil(() => pty.sessionPids().length >= 4, what: 'jobs');
      final before = pty.sessionPids();

      final info = await pty.terminate(grace: const Duration(seconds: 1));
      // Interactive bash ignores SIGTERM, so it is SIGKILLed after the grace.
      expect(
        info.signal,
        anyOf(
          ProcessSignal.sigterm.signalNumber,
          ProcessSignal.sigkill.signalNumber,
        ),
      );
      expect(pty.sessionPids(), isEmpty, reason: 'orphans from $before');
      for (final p in before) {
        final stat = PtyProcess.readProcStat(p);
        expect(stat == null || stat.isZombie, isTrue, reason: 'pid $p alive');
      }
    });

    test('close stops the reader while the child still runs', () async {
      await pty.close();
      expect(pty.isClosed, isTrue);
      await out.done.timeout(const Duration(seconds: 5));
      expect(() => pty.write([0x0a]), throwsA(isA<PtyClosedError>()));
      expect(() => pty.resize(1, 1), throwsA(isA<PtyClosedError>()));

      // Hang-up from the closed master ends the shell; make sure of it.
      pty.kill(ProcessSignal.sigkill);
      await pty.exited.timeout(const Duration(seconds: 5));
    });

    test('large paste is chunked and arrives intact', () async {
      await pty.write(utf8.encode('wc -c\r'));
      await out.waitFor('wc -c');
      final line = '${'a' * 1000}\n';
      final payload = utf8.encode(line * 100); // 100100 bytes, >> 4 KB chunks
      await pty.write(payload, timeout: const Duration(seconds: 20));
      await pty.write([0x04]); // EOF at start of line
      await out.waitFor('100100');
    });
  }, skip: onLinux ? false : 'PTY layer is Linux-only');

  test('invalid dimensions are rejected before any syscall', () {
    expect(
      () => PtyProcess.start(command: '/bin/true', cols: 0, rows: 24),
      throwsArgumentError,
    );
  });
}
