import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tp_web/src/conn/transport.dart';
import 'package:tp_web/src/model/danger.dart';
import 'package:tp_web/src/model/history.dart';
import 'package:tp_web/src/model/prompter_encoding.dart';
import 'package:tp_web/src/model/queue.dart';
import 'package:tp_web/src/model/snippets.dart';

void main() {
  group('history', () {
    test('adds, collapses duplicates, persists and navigates', () {
      final store = MemoryStore();
      final h = CommandHistory(store)
        ..add('ls')
        ..add('ls')
        ..add('pwd');
      expect(h.items, ['ls', 'pwd']);
      expect(CommandHistory(store).items, ['ls', 'pwd'], reason: 'persisted');

      expect(h.previous('draft'), 'pwd');
      expect(h.previous('x'), 'ls');
      expect(h.previous('x'), isNull);
      expect(h.next(), 'pwd');
      expect(h.next(), 'draft', reason: 'draft restored');
      expect(h.next(), isNull);
      expect(h.search('P'), ['pwd']);
    });

    test('capacity and corrupt storage', () {
      final store = MemoryStore()..write('tp.history', '{bad');
      final h = CommandHistory(store, capacity: 2)
        ..add('a')
        ..add('b')
        ..add('c');
      expect(h.items, ['b', 'c']);
    });
  });

  group('danger detector', () {
    final d = DangerDetector();
    test('flags destructive commands', () {
      for (final cmd in [
        'rm -rf /var/lib/docker',
        'sudo rm -fr ~/x',
        'mkfs.ext4 /dev/sdb1',
        'dd if=/dev/zero of=/dev/sda',
        'cat x > /dev/sda',
        'sudo reboot',
        'chmod -R 777 /',
        'docker system prune -a',
        'git push origin main --force',
      ]) {
        expect(d.isDangerous(cmd), isTrue, reason: cmd);
      }
    });
    test('passes everyday commands', () {
      for (final cmd in [
        'ls -la',
        'rm file.txt',
        'docker ps',
        'git push',
        'echo reboot-later',
        'chmod 644 a',
      ]) {
        expect(d.isDangerous(cmd), isFalse, reason: cmd);
      }
    });
  });

  group('snippets', () {
    test('variables expand and library round-trips JSON', () {
      const s = Snippet(
        name: 'logs',
        command: 'docker logs -f {{container}} | grep {{ pattern }}',
      );
      expect(s.variables, ['container', 'pattern']);
      expect(
        s.expand({'container': 'web', 'pattern': 'err'}),
        'docker logs -f web | grep err',
      );
      expect(s.expand({}), s.command);

      final store = MemoryStore();
      SnippetLibrary(store)
        ..save(s)
        ..save(const Snippet(name: 'ps', command: 'docker ps'));
      final copy = SnippetLibrary(store);
      expect(copy.items.map((e) => e.name), ['logs', 'ps']);
      copy.importJson('[{"name":"ps","command":"docker ps -a"}]');
      expect(
        copy.items.singleWhere((e) => e.name == 'ps').command,
        'docker ps -a',
      );
      expect(jsonDecode(copy.exportJson()), hasLength(2));
      expect(() => copy.importJson('{}'), throwsFormatException);
    });
  });

  group('queue', () {
    test('stale after maxAge, acks by msgId', () {
      var now = DateTime(2026, 11, 15, 12);
      final q = CommandQueue(
        maxAge: const Duration(seconds: 60),
        clock: () => now,
      );
      final a = q.enqueue('a', Uint8List(0));
      now = now.add(const Duration(seconds: 30));
      final b = q.enqueue('b', Uint8List(0));
      now = now.add(const Duration(seconds: 40));
      final sendable = q.takeSendable();
      expect(sendable, [b]);
      expect(a.status, DeliveryStatus.stale);
      b
        ..msgId = 7
        ..status = DeliveryStatus.sent;
      q.confirm(a);
      expect(q.takeSendable(), [a], reason: 'confirmed despite age');
      expect(q.ack(7), isTrue);
      expect(b.status, DeliveryStatus.acked);
      expect(q.ack(7), isFalse);
    });
  });

  group('prompter encoding', () {
    test(
      'single line gets CR, multi-line uses bracketed paste when enabled',
      () {
        expect(
          utf8.decode(
            PrompterEncoding.encodeCommand('ls', bracketedPaste: true),
          ),
          'ls\r',
        );
        expect(
          utf8.decode(
            PrompterEncoding.encodeCommand('a\nb', bracketedPaste: true),
          ),
          '\x1b[200~a\rb\x1b[201~\r',
        );
        expect(
          utf8.decode(
            PrompterEncoding.encodeCommand('a\r\nb', bracketedPaste: false),
          ),
          'a\rb\r',
        );
      },
    );

    test('mode tracker follows DEC private modes across chunks', () {
      final t = TerminalModeTracker();
      t.feed(Uint8List.fromList(latin1.encode('\x1b[?2004hTP\$ ')));
      expect(t.bracketedPaste, isTrue);
      t.feed(Uint8List.fromList(latin1.encode('\x1b[?10')));
      t.feed(Uint8List.fromList(latin1.encode('49h\x1b[?1h')));
      expect(t.alternateScreen, isTrue);
      expect(t.applicationCursor, isTrue);
      t.feed(Uint8List.fromList(latin1.encode('\x1b[?1049l\x1b[?2004l')));
      expect(t.alternateScreen, isFalse);
      expect(t.bracketedPaste, isFalse);
    });
  });

  test('queued commands survive a reload; sent ones are not persisted', () {
    final store = MemoryStore();
    var now = DateTime.utc(2026, 11, 18, 12);
    final q = CommandQueue(store: store, clock: () => now);
    q.enqueue('echo a', Uint8List.fromList([1]));
    final b = q.enqueue('echo b', Uint8List.fromList([2]));
    q.markSent(b, 3);

    final restored = CommandQueue(store: store, clock: () => now);
    expect(restored.items.map((c) => c.text), ['echo a']);
    expect(restored.items.single.bytes, [1]);
    expect(restored.takeSendable(), hasLength(1));

    now = now.add(const Duration(minutes: 5));
    final late = CommandQueue(store: store, clock: () => now);
    expect(late.takeSendable(), isEmpty);
    expect(
      late.items.single.status,
      DeliveryStatus.stale,
      reason: 'old commands need confirmation',
    );
    late.discard(late.items.single);
    expect(store.read('tp.queue'), isNull);
  });
}
