import 'dart:convert';

import 'package:tp_protocol/tp_protocol.dart';

import 'conn/transport.dart';
import 'model/danger.dart';

/// Input mode (docs/03).
enum InputMode { prompter, raw }

/// When the key bar is shown (docs/16).
enum KeyBarVisibility { auto, always, hidden }

/// User settings, persisted per agent as JSON. Pure Dart.
final class Settings {
  Settings({
    this.language = '',
    this.defaultMode,
    this.enterSends,
    this.keyBar = KeyBarVisibility.auto,
    this.keyBarScale = 100,
    this.hideKeyRow = false,
    List<KeyBarItem>? customButtons,
    List<String>? dangerPatterns,
    this.fontSize = 14,
    this.autocorrect = false,
  }) : customButtons = customButtons ?? [],
       dangerPatterns =
           dangerPatterns ?? List.of(DangerDetector.defaultPatterns);

  static const String storageKey = 'tp.settings';

  /// `''` = follow the browser, otherwise `en` / `no`.
  String language;

  /// Null = Prompter on touch devices, Raw elsewhere stays Prompter too
  /// (docs/03: Prompter is the default everywhere).
  InputMode? defaultMode;

  /// Null = true on touch devices, false with a physical keyboard.
  bool? enterSends;
  KeyBarVisibility keyBar;

  /// 100, 125 or 150 percent.
  int keyBarScale;
  bool hideKeyRow;
  List<KeyBarItem> customButtons;
  List<String> dangerPatterns;
  int fontSize;
  bool autocorrect;

  /// Resolves [defaultMode] for the device.
  InputMode modeFor({required bool touch}) => defaultMode ?? InputMode.prompter;

  /// Resolves [enterSends] for the device.
  bool enterSendsFor({required bool touch}) => enterSends ?? touch;

  /// Resolves [keyBar] for the device.
  bool keyBarVisibleFor({required bool touch}) => switch (keyBar) {
    KeyBarVisibility.auto => touch,
    KeyBarVisibility.always => true,
    KeyBarVisibility.hidden => false,
  };

  static Settings load(KeyValueStore store) {
    final raw = store.read(storageKey);
    if (raw == null) return Settings();
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return Settings();
      return Settings.fromJson(json);
    } on FormatException {
      return Settings();
    }
  }

  factory Settings.fromJson(Map<String, Object?> json) {
    T? enumByName<T extends Enum>(List<T> values, Object? name) {
      for (final v in values) {
        if (v.name == name) return v;
      }
      return null;
    }

    final buttons = <KeyBarItem>[];
    if (json['customButtons'] case final List<Object?> list) {
      for (final item in list) {
        if (item is Map<String, Object?>) {
          try {
            buttons.add(KeyBarItem.fromJson(item));
          } on FormatException {
            // Skip a broken button instead of losing all settings.
          }
        }
      }
    }
    return Settings(
      language: json['language'] is String ? json['language']! as String : '',
      defaultMode: enumByName(InputMode.values, json['defaultMode']),
      enterSends: json['enterSends'] is bool
          ? json['enterSends']! as bool
          : null,
      keyBar:
          enumByName(KeyBarVisibility.values, json['keyBar']) ??
          KeyBarVisibility.auto,
      keyBarScale: json['keyBarScale'] is int
          ? json['keyBarScale']! as int
          : 100,
      hideKeyRow: json['hideKeyRow'] == true,
      customButtons: buttons,
      dangerPatterns: json['dangerPatterns'] is List
          ? (json['dangerPatterns']! as List).whereType<String>().toList()
          : null,
      fontSize: json['fontSize'] is int ? json['fontSize']! as int : 14,
      autocorrect: json['autocorrect'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'language': language,
    'defaultMode': defaultMode?.name,
    'enterSends': enterSends,
    'keyBar': keyBar.name,
    'keyBarScale': keyBarScale,
    'hideKeyRow': hideKeyRow,
    'customButtons': [for (final b in customButtons) b.toJson()],
    'dangerPatterns': dangerPatterns,
    'fontSize': fontSize,
    'autocorrect': autocorrect,
  };

  void save(KeyValueStore store) =>
      store.write(storageKey, jsonEncode(toJson()));
}
