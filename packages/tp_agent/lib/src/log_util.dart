import 'dart:io';

/// Writes [content] to [path] atomically (temp file + rename) and restricts
/// it to the owner (0600) before it gets its final name.
void writePrivateFile(String path, String content) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  final tmp = File('$path.tmp-$pid');
  tmp.writeAsStringSync(content, flush: true);
  restrictToOwner(tmp.path);
  tmp.renameSync(path);
}

/// `chmod 600`. Dart has no portable API for file modes, and this runs only
/// on Linux, where `chmod` is part of coreutils/BusyBox.
void restrictToOwner(String path) {
  final r = Process.runSync('chmod', ['600', path]);
  if (r.exitCode != 0) {
    throw FileSystemException('chmod 600 failed: ${r.stderr}', path);
  }
}
