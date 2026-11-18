/// UI strings in English and Norwegian (CLAUDE.md: UI engelsk + norsk).
final class Strings {
  const Strings._(this._map);

  static const Strings en = Strings._({
    'mode.prompter': 'Prompter',
    'mode.raw': 'Raw',
    'send': 'Send',
    'newSession': 'New session',
    'settings': 'Settings',
    'snippets': 'Snippets',
    'keybar': 'Key bar',
    'hint.desktop':
        'Enter: new line · Ctrl+Enter: send · ↑↓ history · Ctrl+R search · Ctrl+Shift+Space: mode',
    'hint.desktopEnterSends':
        'Enter: send · Shift+Enter: new line · ↑↓ history · Ctrl+R search',
    'hint.mobile': 'Enter sends · ↵+ adds a line · ↑↓ history',
    'hint.raw': 'Raw mode: keys go straight to the shell.',
    'danger.title': 'This looks destructive. Run it?',
    'danger.run': 'Run',
    'cancel': 'Cancel',
    'queued': 'waiting for network',
    'stale.title': 'Queued more than a minute ago. Send now?',
    'stale.send': 'Send',
    'stale.drop': 'Drop',
    'search.placeholder': 'Search history…',
    'snippet.save': 'Save current text as snippet',
    'snippet.name': 'Snippet name',
    'snippet.value': 'Value for',
    'snippet.export': 'Export / import JSON',
    'snippet.apply': 'Import',
    'snippet.none': 'No snippets yet.',
    'delete': 'Delete',
    'toBottom': 'To bottom',
    'copy': 'Copy',
    'copied': 'Copied',
    'settings.language': 'Language',
    'settings.auto': 'Auto',
    'settings.defaultMode': 'Default mode',
    'settings.enterSends': 'Enter sends the command',
    'settings.keybar': 'Key bar',
    'settings.keybar.auto': 'Auto (touch devices)',
    'settings.keybar.always': 'Always',
    'settings.keybar.hidden': 'Hidden',
    'settings.keybarScale': 'Key bar size',
    'settings.hideKeys': 'Hide F-key row',
    'settings.customButtons': 'My buttons (JSON: label, send, mode)',
    'settings.danger': 'Dangerous command patterns (one regex per line)',
    'settings.fontSize': 'Terminal font size',
    'settings.autocorrect': 'Autocorrect in the Prompter field',
    'settings.clearHistory': 'Clear history',
    'settings.save': 'Save',
    'settings.close': 'Close',
    'settings.invalidJson': 'Invalid JSON',
    'status.connecting': 'connecting',
    'status.connected': 'connected',
    'status.retry': 'retrying in',
    'newline': '↵+',
  });

  static const Strings no = Strings._({
    'mode.prompter': 'Prompter',
    'mode.raw': 'Rå',
    'send': 'Send',
    'newSession': 'Ny sesjon',
    'settings': 'Innstillinger',
    'snippets': 'Snutter',
    'keybar': 'Tastelinje',
    'hint.desktop':
        'Enter: ny linje · Ctrl+Enter: send · ↑↓ historikk · Ctrl+R søk · Ctrl+Shift+Space: modus',
    'hint.desktopEnterSends':
        'Enter: send · Shift+Enter: ny linje · ↑↓ historikk · Ctrl+R søk',
    'hint.mobile': 'Enter sender · ↵+ gir ny linje · ↑↓ historikk',
    'hint.raw': 'Råmodus: tastetrykk går rett til skallet.',
    'danger.title': 'Dette ser destruktivt ut. Kjøre?',
    'danger.run': 'Kjør',
    'cancel': 'Avbryt',
    'queued': 'venter på nett',
    'stale.title': 'Lagt i kø for over et minutt siden. Sende nå?',
    'stale.send': 'Send',
    'stale.drop': 'Forkast',
    'search.placeholder': 'Søk i historikk…',
    'snippet.save': 'Lagre teksten som snutt',
    'snippet.name': 'Navn på snutt',
    'snippet.value': 'Verdi for',
    'snippet.export': 'Eksporter / importer JSON',
    'snippet.apply': 'Importer',
    'snippet.none': 'Ingen snutter ennå.',
    'delete': 'Slett',
    'toBottom': 'Til bunnen',
    'copy': 'Kopier',
    'copied': 'Kopiert',
    'settings.language': 'Språk',
    'settings.auto': 'Automatisk',
    'settings.defaultMode': 'Standardmodus',
    'settings.enterSends': 'Enter sender kommandoen',
    'settings.keybar': 'Tastelinje',
    'settings.keybar.auto': 'Automatisk (berøringsskjerm)',
    'settings.keybar.always': 'Alltid',
    'settings.keybar.hidden': 'Skjult',
    'settings.keybarScale': 'Størrelse på tastelinje',
    'settings.hideKeys': 'Skjul F-tastraden',
    'settings.customButtons': 'Mine knapper (JSON: label, send, mode)',
    'settings.danger': 'Mønstre for farlige kommandoer (ett regex per linje)',
    'settings.fontSize': 'Skriftstørrelse i terminalen',
    'settings.autocorrect': 'Autokorrektur i Prompter-feltet',
    'settings.clearHistory': 'Tøm historikk',
    'settings.save': 'Lagre',
    'settings.close': 'Lukk',
    'settings.invalidJson': 'Ugyldig JSON',
    'status.connecting': 'kobler til',
    'status.connected': 'tilkoblet',
    'status.retry': 'prøver igjen om',
    'newline': '↵+',
  });

  final Map<String, String> _map;

  /// Looks up [key]; falls back to English, then to the key itself.
  String operator [](String key) => _map[key] ?? en._map[key] ?? key;

  /// Picks a language from a BCP-47 tag.
  static Strings forLanguage(String? tag) {
    final t = (tag ?? '').toLowerCase();
    return t.startsWith('nb') || t.startsWith('nn') || t.startsWith('no')
        ? no
        : en;
  }
}
