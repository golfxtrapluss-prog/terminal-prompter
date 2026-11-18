import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../auth/encoding.dart';
import '../config/config.dart';

/// A file operation failed; [status] is the HTTP status to answer with.
final class FileError implements Exception {
  const FileError(this.status, this.code);

  final int status;
  final String code;

  @override
  String toString() => 'FileError($status, $code)';
}

/// One directory entry.
final class FileEntry {
  const FileEntry({
    required this.name,
    required this.type,
    required this.size,
    required this.modified,
  });

  final String name;

  /// `file`, `dir` or `link` (a symlink pointing outside the root or broken).
  final String type;
  final int size;
  final DateTime modified;

  Map<String, Object?> toJson() => {
    'name': name,
    'type': type,
    'size': size,
    'mtime': modified.toUtc().toIso8601String(),
  };
}

/// An upload in progress (docs/02 "Filoverføring"): bytes go to
/// `<target>.tp-<id>.part` next to the target and are renamed into place
/// when complete, so a half-uploaded file never looks finished.
final class Upload {
  Upload({
    required this.id,
    required this.target,
    required this.size,
    required this.owner,
    required this.created,
  }) : part = '$target.tp-$id.part';

  final String id;
  final String target;
  final String part;
  final int size;

  /// Login that started it; only that login may continue it.
  final String owner;
  final DateTime created;
  bool _busy = false;

  /// Bytes received so far (the length of the part file).
  int get offset {
    final f = File(part);
    return f.existsSync() ? f.lengthSync() : 0;
  }
}

/// File browsing, download and resumable upload confined to `files.root`.
final class FileService {
  FileService(this.config, {required String home, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      root = _resolveRoot(config.root, home);

  /// Unfinished uploads are dropped after this long.
  static const Duration uploadLifetime = Duration(hours: 24);

  final FilesConfig config;
  final DateTime Function() _clock;

  /// Real (symlink-free) root directory.
  final String root;
  final Map<String, Upload> _uploads = {};

  static String _resolveRoot(String configured, String home) {
    var path = configured;
    if (path == '~') {
      path = home;
    } else if (path.startsWith('~/')) {
      path = p.join(home, path.substring(2));
    }
    final dir = Directory(path);
    if (!dir.existsSync()) throw FileError(500, 'root_missing');
    return dir.resolveSymbolicLinksSync();
  }

  /// Maps a client path (absolute, or relative to the root) to a real path
  /// inside the root. Symlinks are resolved before the check, so a link
  /// pointing out of the root is refused like `../../etc/shadow` (docs/05).
  String resolveExisting(String requested) {
    final candidate = _candidate(requested);
    final type = FileSystemEntity.typeSync(candidate, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw const FileError(404, 'not_found');
    }
    final String real;
    try {
      real = File(candidate).resolveSymbolicLinksSync();
    } on FileSystemException {
      throw const FileError(404, 'not_found'); // broken link
    }
    _checkInside(real);
    return real;
  }

  String _candidate(String requested) {
    if (requested.contains('\u0000') || requested.length > 4096) {
      throw const FileError(400, 'bad_path');
    }
    final joined = p.isAbsolute(requested)
        ? requested
        : p.join(root, requested);
    final normalized = p.normalize(joined);
    // Cheap early check; the real check happens after resolving symlinks.
    if (normalized != root && !p.isWithin(root, normalized)) {
      throw const FileError(400, 'outside_root');
    }
    return normalized;
  }

  void _checkInside(String real) {
    if (real != root && !p.isWithin(root, real)) {
      throw const FileError(400, 'outside_root');
    }
  }

  /// Lists a directory, directories first, then by name.
  Map<String, Object?> list(String requested) {
    final dir = resolveExisting(requested.isEmpty ? root : requested);
    if (FileSystemEntity.typeSync(dir) != FileSystemEntityType.directory) {
      throw const FileError(400, 'not_a_directory');
    }
    final entries = <FileEntry>[];
    try {
      for (final e in Directory(dir).listSync(followLinks: false)) {
        final name = p.basename(e.path);
        var type = 'file';
        var stat = e.statSync();
        if (FileSystemEntity.isLinkSync(e.path)) {
          // Follow the link only if it stays inside the root.
          try {
            final target = File(e.path).resolveSymbolicLinksSync();
            _checkInside(target);
            stat = File(target).statSync();
            type = stat.type == FileSystemEntityType.directory ? 'dir' : 'file';
          } on Object {
            type = 'link';
          }
        } else if (stat.type == FileSystemEntityType.directory) {
          type = 'dir';
        }
        entries.add(
          FileEntry(
            name: name,
            type: type,
            size: type == 'file' ? stat.size : 0,
            modified: stat.modified,
          ),
        );
      }
    } on FileSystemException {
      throw const FileError(403, 'permission_denied');
    }
    entries.sort((a, b) {
      final ad = a.type == 'dir' ? 0 : 1;
      final bd = b.type == 'dir' ? 0 : 1;
      return ad != bd
          ? ad - bd
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return {
      'path': dir,
      'root': root,
      'parent': dir == root ? null : p.dirname(dir),
      'chunk_size': config.chunkSize,
      'max_upload': config.maxUpload,
      'entries': [for (final e in entries) e.toJson()],
    };
  }

  /// Real path of a regular file for download.
  File downloadFile(String requested) {
    final real = resolveExisting(requested);
    if (FileSystemEntity.typeSync(real) != FileSystemEntityType.file) {
      throw const FileError(400, 'not_a_file');
    }
    return File(real);
  }

  /// Starts (or, for the same target and size, resumes) an upload.
  Upload startUpload({
    required String dir,
    required String name,
    required int size,
    required bool overwrite,
    required String owner,
  }) {
    sweep();
    if (size < 0 || size > config.maxUpload) {
      throw const FileError(413, 'too_large');
    }
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\u0000') ||
        name.length > 255) {
      throw const FileError(400, 'bad_name');
    }
    final realDir = resolveExisting(dir.isEmpty ? root : dir);
    if (FileSystemEntity.typeSync(realDir) != FileSystemEntityType.directory) {
      throw const FileError(400, 'not_a_directory');
    }
    final target = p.join(realDir, name);
    final existing = FileSystemEntity.typeSync(target, followLinks: false);
    if (existing == FileSystemEntityType.directory) {
      throw const FileError(409, 'is_a_directory');
    }
    if (existing == FileSystemEntityType.link) {
      // Never write through a symlink.
      throw const FileError(400, 'target_is_symlink');
    }
    if (existing != FileSystemEntityType.notFound && !overwrite) {
      throw const FileError(409, 'exists');
    }
    for (final u in _uploads.values) {
      if (u.target == target && u.size == size && u.owner == owner) {
        return u; // resume
      }
    }
    if (_uploads.length >= 64) throw const FileError(429, 'too_many_uploads');
    final upload = Upload(
      id: b64Url(randomBytes(12)),
      target: target,
      size: size,
      owner: owner,
      created: _clock(),
    );
    try {
      File(upload.part).writeAsBytesSync(const [], flush: true);
    } on FileSystemException {
      throw const FileError(403, 'permission_denied');
    }
    _uploads[upload.id] = upload;
    return upload;
  }

  Upload upload(String id, String owner) {
    final u = _uploads[id];
    if (u == null || u.owner != owner) {
      throw const FileError(404, 'unknown_upload');
    }
    return u;
  }

  /// Appends [body] at [offset]. The offset must equal the bytes already
  /// received (otherwise 409 with the current offset, so the client can
  /// resume). Returns the new offset; completes the upload at [Upload.size].
  Future<int> appendChunk(Upload u, int offset, Stream<List<int>> body) async {
    if (u._busy) throw const FileError(409, 'busy');
    if (offset != u.offset) throw const FileError(409, 'offset_mismatch');
    u._busy = true;
    final sink = File(u.part).openSync(mode: FileMode.append);
    var written = 0;
    try {
      await for (final chunk in body) {
        written += chunk.length;
        if (written > config.chunkSize || offset + written > u.size) {
          throw const FileError(413, 'chunk_too_large');
        }
        sink.writeFromSync(
          chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
        );
      }
      sink.flushSync();
    } finally {
      // Whatever arrived before a drop stays; the client resumes from it.
      sink.closeSync();
      u._busy = false;
    }
    final now = u.offset;
    if (now == u.size) {
      final raf = File(u.part).openSync(mode: FileMode.append);
      raf
        ..flushSync()
        ..closeSync();
      File(u.part).renameSync(u.target);
      _uploads.remove(u.id);
    }
    return now;
  }

  /// Cancels an upload and deletes its part file.
  void cancel(Upload u) {
    _uploads.remove(u.id);
    try {
      File(u.part).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// Drops uploads older than [uploadLifetime].
  void sweep() {
    final now = _clock();
    for (final u in _uploads.values.toList()) {
      if (now.difference(u.created) > uploadLifetime) cancel(u);
    }
  }
}
