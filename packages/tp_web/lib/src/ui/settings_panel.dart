import 'dart:convert';
import 'dart:js_interop';

import 'package:tp_protocol/tp_protocol.dart';
import 'package:web/web.dart' as web;

import '../i18n/strings.dart';
import '../settings.dart';
import 'dom.dart';

/// Settings side panel. Saves to storage and reports what changed.
final class SettingsPanel {
  SettingsPanel({
    required this.strings,
    required this.settings,
    required this.onSave,
    required this.onClearHistory,
  }) {
    element = el('aside', className: 'settings hidden');
  }

  final Strings strings;
  final Settings settings;

  /// Called after the user saved; `reload` is true when the page must reload
  /// (language change).
  final void Function({required bool reload}) onSave;
  final void Function() onClearHistory;
  late final web.HTMLElement element;

  bool get isOpen => !element.classList.contains('hidden');

  void toggle() => isOpen ? close() : open();

  void close() => element.classList.add('hidden');

  void open() {
    _render();
    element.classList.remove('hidden');
  }

  void _render() {
    element.textContent = '';
    final form = el('div', className: 'settings-form');
    final languageBefore = settings.language;

    final language = _select(form, strings['settings.language'], {
      '': strings['settings.auto'],
      'en': 'English',
      'no': 'Norsk',
    }, settings.language);
    final mode = _select(form, strings['settings.defaultMode'], {
      '': strings['settings.auto'],
      'prompter': strings['mode.prompter'],
      'raw': strings['mode.raw'],
    }, settings.defaultMode?.name ?? '');
    final enter = _select(form, strings['settings.enterSends'], {
      '': strings['settings.auto'],
      'true': strings['on'],
      'false': strings['off'],
    }, settings.enterSends?.toString() ?? '');
    final keybar = _select(form, strings['settings.keybar'], {
      'auto': strings['settings.keybar.auto'],
      'always': strings['settings.keybar.always'],
      'hidden': strings['settings.keybar.hidden'],
    }, settings.keyBar.name);
    final scale = _select(form, strings['settings.keybarScale'], {
      '100': '100 %',
      '125': '125 %',
      '150': '150 %',
    }, '${settings.keyBarScale}');
    final hideKeys = _checkbox(
      form,
      strings['settings.hideKeys'],
      settings.hideKeyRow,
    );
    final autocorrect = _checkbox(
      form,
      strings['settings.autocorrect'],
      settings.autocorrect,
    );
    final font = _number(
      form,
      strings['settings.fontSize'],
      settings.fontSize,
      8,
      32,
    );
    final buttons = _textarea(
      form,
      strings['settings.customButtons'],
      const JsonEncoder.withIndent(
        '  ',
      ).convert([for (final b in settings.customButtons) b.toJson()]),
    );
    final danger = _textarea(
      form,
      strings['settings.danger'],
      settings.dangerPatterns.join('\n'),
    );

    final error = el('div', className: 'settings-error');
    final actions = el('div', className: 'settings-actions');
    final save = el(
      'button',
      className: 'primary',
      text: strings['settings.save'],
    );
    save.onclick = ((web.Event _) {
      try {
        final decoded = jsonDecode(
          buttons.value.trim().isEmpty ? '[]' : buttons.value,
        );
        if (decoded is! List) throw const FormatException('expected a list');
        settings.customButtons = [
          for (final item in decoded)
            if (item is Map<String, Object?>)
              KeyBarItem.fromJson(item)
            else
              throw const FormatException('bad item'),
        ];
      } on FormatException catch (e) {
        error.textContent = '${strings['settings.invalidJson']}: ${e.message}';
        return;
      }
      settings
        ..language = language.value
        ..defaultMode = InputMode.values
            .where((m) => m.name == mode.value)
            .firstOrNull
        ..enterSends = enter.value.isEmpty ? null : enter.value == 'true'
        ..keyBar = KeyBarVisibility.values.firstWhere(
          (k) => k.name == keybar.value,
        )
        ..keyBarScale = int.parse(scale.value)
        ..hideKeyRow = hideKeys.checked
        ..autocorrect = autocorrect.checked
        ..fontSize = int.tryParse(font.value)?.clamp(8, 32) ?? settings.fontSize
        ..dangerPatterns = danger.value
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
      close();
      onSave(reload: settings.language != languageBefore);
    }).toJS;
    final clear = el('button', text: strings['settings.clearHistory']);
    clear.onclick = ((web.Event _) => onClearHistory()).toJS;
    final closeBtn = el('button', text: strings['settings.close']);
    closeBtn.onclick = ((web.Event _) => close()).toJS;
    actions
      ..appendChild(save)
      ..appendChild(clear)
      ..appendChild(closeBtn);
    element
      ..appendChild(el('h2', text: strings['settings']))
      ..appendChild(form)
      ..appendChild(error)
      ..appendChild(actions);
  }

  web.HTMLSelectElement _select(
    web.HTMLElement form,
    String label,
    Map<String, String> options,
    String value,
  ) {
    final select = el('select') as web.HTMLSelectElement;
    for (final entry in options.entries) {
      final option = el('option', text: entry.value) as web.HTMLOptionElement;
      option.value = entry.key;
      option.selected = entry.key == value;
      select.appendChild(option);
    }
    form.appendChild(_labelled(label, select));
    return select;
  }

  web.HTMLInputElement _checkbox(
    web.HTMLElement form,
    String label,
    bool value,
  ) {
    final input = el('input') as web.HTMLInputElement;
    input
      ..type = 'checkbox'
      ..checked = value;
    form.appendChild(_labelled(label, input, inline: true));
    return input;
  }

  web.HTMLInputElement _number(
    web.HTMLElement form,
    String label,
    int value,
    int min,
    int max,
  ) {
    final input = el('input') as web.HTMLInputElement;
    input
      ..type = 'number'
      ..min = '$min'
      ..max = '$max'
      ..value = '$value';
    form.appendChild(_labelled(label, input));
    return input;
  }

  web.HTMLTextAreaElement _textarea(
    web.HTMLElement form,
    String label,
    String value,
  ) {
    final area = el('textarea') as web.HTMLTextAreaElement;
    area
      ..rows = 4
      ..value = value
      ..spellcheck = false;
    form.appendChild(_labelled(label, area));
    return area;
  }

  web.HTMLElement _labelled(
    String text,
    web.HTMLElement control, {
    bool inline = false,
  }) {
    final label = el('label', className: inline ? 'inline' : null);
    if (inline) {
      label
        ..appendChild(control)
        ..appendChild(el('span', text: text));
    } else {
      label
        ..appendChild(el('span', text: text))
        ..appendChild(control);
    }
    return label;
  }
}
