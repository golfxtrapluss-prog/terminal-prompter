import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

/// Installs a JSON-lines handler on the root logger (docs/02: structured
/// logging to stdout; journald keeps the rest).
///
/// A record whose message is a `Map` is treated as structured fields; its
/// `msg` entry becomes the message. Never log passwords, tokens or PTY output.
void installJsonLogging({Level level = Level.INFO, StringSink? sink}) {
  Logger.root.level = level;
  Logger.root.onRecord.listen((record) {
    final out = <String, Object?>{
      'ts': record.time.toUtc().toIso8601String(),
      'level': record.level.name.toLowerCase(),
      'logger': record.loggerName,
    };
    if (record.object case final Map<String, Object?> fields) {
      out.addAll(fields);
      out.putIfAbsent('msg', () => record.message);
    } else {
      out['msg'] = record.message;
    }
    if (record.error != null) out['error'] = record.error.toString();
    if (record.stackTrace != null && record.level >= Level.SEVERE) {
      out['stack'] = record.stackTrace.toString();
    }
    (sink ?? stdout).writeln(jsonEncode(out));
  });
}
