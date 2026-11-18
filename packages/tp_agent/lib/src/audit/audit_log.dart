import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import '../log_util.dart';

/// Append-only JSONL audit log (docs/05 "Auditlogg-format"). Never receives
/// passwords, tokens, codes or PTY output; command lines only from the
/// Prompter and only when `audit.log_input` is on.
final class AuditLog {
  AuditLog({
    required this.path,
    this.enabled = true,
    this.maxBytes = 10 * 1024 * 1024,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// A log that drops everything (tests, `audit.enabled = false`).
  AuditLog.disabled() : this(path: '', enabled: false);

  final String path;
  final bool enabled;
  final int maxBytes;
  final DateTime Function() _clock;
  final Logger _log = Logger('audit');
  RandomAccessFile? _file;
  int _size = 0;

  /// Appends one event. Failures are logged, never thrown: auditing must
  /// not take the terminal down.
  void record(String event, [Map<String, Object?> fields = const {}]) {
    if (!enabled) return;
    final line =
        '${jsonEncode({'ts': _clock().toUtc().toIso8601String(), 'ev': event, ...fields})}\n';
    try {
      final file = _open();
      final bytes = utf8.encode(line);
      file.writeFromSync(bytes);
      file.flushSync();
      _size += bytes.length;
      if (_size > maxBytes) _rotate();
    } on FileSystemException catch (e) {
      _log.warning({'msg': 'audit_write_failed', 'path': path}, e);
    }
  }

  RandomAccessFile _open() {
    final existing = _file;
    if (existing != null) return existing;
    final f = File(path);
    f.parent.createSync(recursive: true);
    final created = !f.existsSync();
    final raf = f.openSync(mode: FileMode.append);
    if (created) restrictToOwner(path);
    _size = raf.lengthSync();
    return _file = raf;
  }

  void _rotate() {
    _file?.closeSync();
    _file = null;
    File(path).renameSync('$path.1');
    _size = 0;
  }

  void close() {
    _file?.closeSync();
    _file = null;
  }
}
