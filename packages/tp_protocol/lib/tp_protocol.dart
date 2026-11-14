/// Shared protocol definitions for Terminal Prompter.
///
/// Used by both the agent (`dart:io`) and the web client (`package:web`), so
/// this package must stay pure Dart: no `dart:io`, `dart:html` or
/// `package:web` imports.
library;

export 'src/limits.dart';
export 'src/protocol_version.dart';
