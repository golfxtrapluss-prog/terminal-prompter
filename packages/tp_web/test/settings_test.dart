import 'package:test/test.dart';
import 'package:tp_protocol/tp_protocol.dart';
import 'package:tp_web/src/conn/transport.dart';
import 'package:tp_web/src/i18n/strings.dart';
import 'package:tp_web/src/settings.dart';

void main() {
  test('defaults depend on device', () {
    final s = Settings();
    expect(s.modeFor(touch: true), InputMode.prompter);
    expect(s.modeFor(touch: false), InputMode.prompter);
    expect(s.enterSendsFor(touch: true), isTrue);
    expect(s.enterSendsFor(touch: false), isFalse);
    expect(s.keyBarVisibleFor(touch: true), isTrue);
    expect(s.keyBarVisibleFor(touch: false), isFalse);
  });

  test('round-trips through storage and tolerates junk', () {
    final store = MemoryStore();
    Settings(
      language: 'no',
      defaultMode: InputMode.raw,
      enterSends: false,
      keyBar: KeyBarVisibility.always,
      keyBarScale: 125,
      customButtons: const [
        CustomItem(label: 'ps', send: 'docker ps', run: true),
      ],
      dangerPatterns: const [r'\brm\b'],
      fontSize: 16,
    ).save(store);
    final back = Settings.load(store);
    expect(back.language, 'no');
    expect(back.defaultMode, InputMode.raw);
    expect(back.enterSends, isFalse);
    expect(back.keyBar, KeyBarVisibility.always);
    expect(back.keyBarScale, 125);
    expect((back.customButtons.single as CustomItem).run, isTrue);
    expect(back.dangerPatterns, [r'\brm\b']);
    expect(back.fontSize, 16);

    store.write(Settings.storageKey, 'not json');
    expect(Settings.load(store).fontSize, 14);
  });

  test('strings fall back to English and pick Norwegian from nb/nn/no', () {
    expect(Strings.forLanguage('nb-NO')['send'], 'Send');
    expect(Strings.forLanguage('nn')['mode.raw'], 'Rå');
    expect(Strings.forLanguage('en-US')['mode.raw'], 'Raw');
    expect(Strings.no['does.not.exist'], 'does.not.exist');
  });
}
