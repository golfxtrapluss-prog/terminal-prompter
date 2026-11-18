import 'package:test/test.dart';
import 'package:tp_protocol/tp_protocol.dart';

void main() {
  test('cursor keys honour application cursor mode', () {
    expect(KeyEncoder.encodeKey(TerminalKey.arrowUp), '\x1b[A');
    expect(
      KeyEncoder.encodeKey(TerminalKey.arrowUp, applicationCursor: true),
      '\x1bOA',
    );
    expect(KeyEncoder.encodeKey(TerminalKey.arrowLeft), '\x1b[D');
    expect(
      KeyEncoder.encodeKey(TerminalKey.home, applicationCursor: true),
      '\x1bOH',
    );
  });

  test('function and editing keys match docs/16', () {
    expect(KeyEncoder.encodeKey(TerminalKey.f1), '\x1bOP');
    expect(KeyEncoder.encodeKey(TerminalKey.f5), '\x1b[15~');
    expect(KeyEncoder.encodeKey(TerminalKey.f10), '\x1b[21~');
    expect(KeyEncoder.encodeKey(TerminalKey.f12), '\x1b[24~');
    expect(KeyEncoder.encodeKey(TerminalKey.delete), '\x1b[3~');
    expect(KeyEncoder.encodeKey(TerminalKey.pageDown), '\x1b[6~');
    expect(KeyEncoder.encodeKey(TerminalKey.escape), '\x1b');
    expect(KeyEncoder.encodeKey(TerminalKey.backspace), '\x7f');
  });

  test('ctrl and alt modifiers', () {
    expect(KeyEncoder.encodeChar('c', Modifier.ctrl), '\x03');
    expect(KeyEncoder.encodeChar('C', Modifier.ctrl), '\x03');
    expect(KeyEncoder.encodeChar('d', Modifier.ctrl), '\x04');
    expect(KeyEncoder.encodeChar('[', Modifier.ctrl), '\x1b');
    expect(KeyEncoder.encodeChar(' ', Modifier.ctrl), '\x00');
    expect(KeyEncoder.encodeChar('/', Modifier.ctrl), '\x1f');
    expect(
      KeyEncoder.encodeChar('1', Modifier.ctrl),
      '1',
      reason: 'unmodifiable',
    );
    expect(KeyEncoder.encodeChar('x', Modifier.alt), '\x1bx');
    expect(KeyEncoder.encodeChar('x', Modifier.none), 'x');
  });

  test('modifier state: tap arms, double tap locks, third releases', () {
    final s = ModifierState();
    s.tap(Modifier.ctrl);
    expect(s.modifier, Modifier.ctrl);
    expect(s.consume(), Modifier.ctrl);
    expect(s.modifier, Modifier.none, reason: 'one-shot');

    s.tap(Modifier.ctrl);
    s.tap(Modifier.ctrl);
    expect(s.locked, isTrue);
    expect(s.consume(), Modifier.ctrl);
    expect(s.modifier, Modifier.ctrl, reason: 'locked survives');
    s.tap(Modifier.ctrl);
    expect(s.modifier, Modifier.none);

    s.tap(Modifier.ctrl);
    s.tap(Modifier.alt);
    expect(s.modifier, Modifier.alt, reason: 'switching replaces');
    expect(s.locked, isFalse);
  });

  test('default rows contain the documented keys and round-trip JSON', () {
    expect(KeyBarRows.basic.first, isA<KeyItem>());
    expect(KeyBarRows.basic.whereType<ModifierItem>(), hasLength(2));
    expect(
      KeyBarRows.symbols.whereType<CharItem>().map((c) => c.char),
      containsAll(['|', r'$', '>', '#']),
    );
    expect(
      KeyBarRows.keys.whereType<KeyItem>().map((k) => k.key),
      contains(TerminalKey.f10),
    );
    for (final row in KeyBarRows.defaults) {
      for (final item in row) {
        final back = KeyBarItem.fromJson(item.toJson());
        expect(back.toJson(), item.toJson());
      }
    }
    final custom =
        KeyBarItem.fromJson({'label': 'ps', 'send': 'docker ps', 'mode': 'run'})
            as CustomItem;
    expect(custom.run, isTrue);
    expect(() => KeyBarItem.fromJson({'key': 'nope'}), throwsFormatException);
  });
}
