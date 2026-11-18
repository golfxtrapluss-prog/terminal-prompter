/// Terminal key table for the key bar (docs/16), shared with a future
/// Flutter client. Pure Dart, no platform code.
library;

/// Escape character.
const String esc = '\x1b';

/// Keys the key bar can send that are not plain characters.
enum TerminalKey {
  /// Escape.
  escape('Esc'),

  /// Tab.
  tab('Tab'),

  /// Enter / carriage return.
  enter('Enter'),

  /// Backspace (DEL byte).
  backspace('⌫'),

  /// Cursor up.
  arrowUp('↑'),

  /// Cursor down.
  arrowDown('↓'),

  /// Cursor left.
  arrowLeft('←'),

  /// Cursor right.
  arrowRight('→'),

  /// Home.
  home('Home'),

  /// End.
  end('End'),

  /// Page up.
  pageUp('PgUp'),

  /// Page down.
  pageDown('PgDn'),

  /// Forward delete.
  delete('Del'),

  /// Insert.
  insert('Ins'),

  /// Function key F1.
  f1('F1'),

  /// Function key F2.
  f2('F2'),

  /// Function key F3.
  f3('F3'),

  /// Function key F4.
  f4('F4'),

  /// Function key F5.
  f5('F5'),

  /// Function key F6.
  f6('F6'),

  /// Function key F7.
  f7('F7'),

  /// Function key F8.
  f8('F8'),

  /// Function key F9.
  f9('F9'),

  /// Function key F10.
  f10('F10'),

  /// Function key F11.
  f11('F11'),

  /// Function key F12.
  f12('F12');

  const TerminalKey(this.label);

  /// Label shown on the key bar.
  final String label;

  /// Looks up a key by its enum name (used for stored custom rows).
  static TerminalKey? byName(String name) {
    for (final k in values) {
      if (k.name == name) return k;
    }
    return null;
  }
}

/// Modifier state of the key bar.
enum Modifier {
  /// No modifier.
  none,

  /// Control.
  ctrl,

  /// Alt / Meta (sends ESC prefix).
  alt,
}

/// Encodes keys and characters to the byte sequences a PTY expects in Raw
/// mode (docs/16 "Hva en tast gjør").
abstract final class KeyEncoder {
  /// Sequence for [key]. [applicationCursor] selects `ESC O x` instead of
  /// `ESC [ x` for arrows and Home/End (DECCKM).
  static String encodeKey(TerminalKey key, {bool applicationCursor = false}) {
    final cursor = applicationCursor ? '${esc}O' : '$esc[';
    return switch (key) {
      TerminalKey.escape => esc,
      TerminalKey.tab => '\t',
      TerminalKey.enter => '\r',
      TerminalKey.backspace => '\x7f',
      TerminalKey.arrowUp => '${cursor}A',
      TerminalKey.arrowDown => '${cursor}B',
      TerminalKey.arrowRight => '${cursor}C',
      TerminalKey.arrowLeft => '${cursor}D',
      TerminalKey.home => '${cursor}H',
      TerminalKey.end => '${cursor}F',
      TerminalKey.pageUp => '$esc[5~',
      TerminalKey.pageDown => '$esc[6~',
      TerminalKey.delete => '$esc[3~',
      TerminalKey.insert => '$esc[2~',
      TerminalKey.f1 => '${esc}OP',
      TerminalKey.f2 => '${esc}OQ',
      TerminalKey.f3 => '${esc}OR',
      TerminalKey.f4 => '${esc}OS',
      TerminalKey.f5 => '$esc[15~',
      TerminalKey.f6 => '$esc[17~',
      TerminalKey.f7 => '$esc[18~',
      TerminalKey.f8 => '$esc[19~',
      TerminalKey.f9 => '$esc[20~',
      TerminalKey.f10 => '$esc[21~',
      TerminalKey.f11 => '$esc[23~',
      TerminalKey.f12 => '$esc[24~',
    };
  }

  /// Applies [modifier] to a typed character: Ctrl maps letters and the
  /// usual punctuation to control codes (`code & 0x1F`), Alt prefixes ESC.
  /// Characters Ctrl cannot modify are returned unchanged.
  static String encodeChar(String char, Modifier modifier) {
    switch (modifier) {
      case Modifier.none:
        return char;
      case Modifier.alt:
        return '$esc$char';
      case Modifier.ctrl:
        if (char.length != 1) return char;
        final code = char.toUpperCase().codeUnitAt(0);
        if (code >= 0x40 && code <= 0x5F) {
          return String.fromCharCode(code & 0x1F);
        }
        return switch (char) {
          ' ' || '2' => '\x00',
          '3' => esc,
          '4' => '\x1c',
          '5' => '\x1d',
          '6' => '\x1e',
          '7' || '/' => '\x1f',
          '8' || '?' => '\x7f',
          _ => char,
        };
    }
  }
}

/// One button on the key bar.
sealed class KeyBarItem {
  const KeyBarItem();

  /// Parses the compact stored form used in settings JSON.
  factory KeyBarItem.fromJson(Map<String, Object?> json) {
    final key = json['key'];
    if (key is String) {
      final k = TerminalKey.byName(key);
      if (k == null) throw FormatException('unknown key "$key"');
      return KeyItem(k);
    }
    final mod = json['modifier'];
    if (mod is String) {
      return ModifierItem(mod == 'alt' ? Modifier.alt : Modifier.ctrl);
    }
    final char = json['char'];
    if (char is String) {
      final alt = json['alt'];
      return CharItem(char, longPress: alt is String ? alt : null);
    }
    final label = json['label'];
    final send = json['send'];
    if (label is String && send is String) {
      return CustomItem(label: label, send: send, run: json['mode'] == 'run');
    }
    throw const FormatException('invalid key bar item');
  }

  /// Stored form.
  Map<String, Object?> toJson();
}

/// A character (with optional long-press alternative).
final class CharItem extends KeyBarItem {
  /// Creates a character button.
  const CharItem(this.char, {this.longPress});

  /// Character inserted or sent on tap.
  final String char;

  /// Character produced by a long press, if any.
  final String? longPress;

  @override
  Map<String, Object?> toJson() => {
    'char': char,
    if (longPress != null) 'alt': longPress,
  };
}

/// A terminal key.
final class KeyItem extends KeyBarItem {
  /// Creates a key button.
  const KeyItem(this.key);

  /// The key.
  final TerminalKey key;

  @override
  Map<String, Object?> toJson() => {'key': key.name};
}

/// Ctrl or Alt (sticky / lockable).
final class ModifierItem extends KeyBarItem {
  /// Creates a modifier button.
  const ModifierItem(this.modifier);

  /// Ctrl or Alt.
  final Modifier modifier;

  @override
  Map<String, Object?> toJson() => {'modifier': modifier.name};
}

/// User-defined button: inserts text, or runs it as a command.
final class CustomItem extends KeyBarItem {
  /// Creates a user button.
  const CustomItem({required this.label, required this.send, this.run = false});

  /// Text on the button.
  final String label;

  /// Text to insert or run.
  final String send;

  /// True to run [send] as a command (adds Enter).
  final bool run;

  @override
  Map<String, Object?> toJson() => {
    'label': label,
    'send': send,
    'mode': run ? 'run' : 'insert',
  };
}

/// Default rows from docs/16.
abstract final class KeyBarRows {
  /// Row 1: basics.
  static const List<KeyBarItem> basic = [
    KeyItem(TerminalKey.escape),
    KeyItem(TerminalKey.tab),
    ModifierItem(Modifier.ctrl),
    ModifierItem(Modifier.alt),
    KeyItem(TerminalKey.arrowLeft),
    KeyItem(TerminalKey.arrowDown),
    KeyItem(TerminalKey.arrowUp),
    KeyItem(TerminalKey.arrowRight),
    CharItem('|'),
    CharItem('/', longPress: r'\'),
    CharItem('-', longPress: '_'),
    CharItem('~'),
  ];

  /// Row 2: symbols.
  static const List<KeyBarItem> symbols = [
    CharItem('|'),
    CharItem('/', longPress: r'\'),
    CharItem(r'\'),
    CharItem('~'),
    CharItem(r'$'),
    CharItem('>'),
    CharItem('<', longPress: '>'),
    CharItem('&'),
    CharItem('*'),
    CharItem(';'),
    CharItem(':'),
    CharItem('"'),
    CharItem("'", longPress: '"'),
    CharItem('`'),
    CharItem('='),
    CharItem('+'),
    CharItem('_'),
    CharItem('#'),
    CharItem('@'),
    CharItem('!'),
    CharItem('?'),
    CharItem('(', longPress: ')'),
    CharItem(')'),
    CharItem('[', longPress: ']'),
    CharItem(']'),
    CharItem('{', longPress: '}'),
    CharItem('}'),
    CharItem('%'),
    CharItem('^'),
  ];

  /// Row 3: function and navigation keys.
  static const List<KeyBarItem> keys = [
    KeyItem(TerminalKey.f1),
    KeyItem(TerminalKey.f2),
    KeyItem(TerminalKey.f3),
    KeyItem(TerminalKey.f4),
    KeyItem(TerminalKey.f5),
    KeyItem(TerminalKey.f6),
    KeyItem(TerminalKey.f7),
    KeyItem(TerminalKey.f8),
    KeyItem(TerminalKey.f9),
    KeyItem(TerminalKey.f10),
    KeyItem(TerminalKey.f11),
    KeyItem(TerminalKey.f12),
    KeyItem(TerminalKey.home),
    KeyItem(TerminalKey.end),
    KeyItem(TerminalKey.pageUp),
    KeyItem(TerminalKey.pageDown),
    KeyItem(TerminalKey.delete),
    KeyItem(TerminalKey.insert),
  ];

  /// Row 4: the user's own buttons (empty by default).
  static const List<KeyBarItem> custom = [];

  /// All default rows in order.
  static const List<List<KeyBarItem>> defaults = [basic, symbols, keys, custom];
}

/// Sticky/lockable modifier state (docs/16): one tap arms the modifier
/// for the next key, two taps lock it, a further tap releases it.
final class ModifierState {
  Modifier _modifier = Modifier.none;
  bool _locked = false;

  /// Currently active modifier.
  Modifier get modifier => _modifier;

  /// True when locked (survives key presses).
  bool get locked => _locked;

  /// Handles a tap on a modifier button.
  void tap(Modifier m) {
    if (_modifier != m) {
      _modifier = m;
      _locked = false;
    } else if (!_locked) {
      _locked = true;
    } else {
      _modifier = Modifier.none;
      _locked = false;
    }
  }

  /// Returns the modifier to apply to the next key and clears it unless
  /// locked.
  Modifier consume() {
    final m = _modifier;
    if (!_locked) _modifier = Modifier.none;
    return m;
  }

  /// Clears everything.
  void reset() {
    _modifier = Modifier.none;
    _locked = false;
  }
}
