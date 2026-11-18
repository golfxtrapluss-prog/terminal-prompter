import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tp_agent/src/config/config.dart';
import 'package:tp_agent/src/files/file_service.dart';

void main() {
  late Directory home;
  late Directory outside;
  late FileService files;

  setUp(() {
    home = Directory.systemTemp.createTempSync('tp_files_home_');
    outside = Directory.systemTemp.createTempSync('tp_files_out_');
    File('${outside.path}/secret.txt').writeAsStringSync('nope');
    Directory('${home.path}/docs').createSync();
    File('${home.path}/docs/a.txt').writeAsStringSync('hello');
    Link('${home.path}/escape').createSync(outside.path);
    Link('${home.path}/inside-link').createSync('${home.path}/docs');
    final config = AgentConfig.parse(
      '[files]\nroot = "~"\nchunk_size = "4096"\nmax_upload = "1MB"\n',
    );
    files = FileService(config.files, home: home.path);
  });

  tearDown(() {
    home.deleteSync(recursive: true);
    outside.deleteSync(recursive: true);
  });

  Matcher fileError(int status, String code) => throwsA(
    isA<FileError>()
        .having((e) => e.status, 'status', status)
        .having((e) => e.code, 'code', code),
  );

  test('path traversal and escaping symlinks are refused with 400', () {
    expect(
      () => files.resolveExisting('../../etc/shadow'),
      fileError(400, 'outside_root'),
    );
    expect(
      () => files.resolveExisting('/etc/shadow'),
      fileError(400, 'outside_root'),
    );
    expect(
      () => files.resolveExisting('docs/../../x'),
      fileError(400, 'outside_root'),
    );
    expect(
      () => files.resolveExisting('escape/secret.txt'),
      fileError(400, 'outside_root'),
    );
    expect(
      () => files.resolveExisting('bad\u0000name'),
      fileError(400, 'bad_path'),
    );
    expect(
      () => files.downloadFile('escape/secret.txt'),
      fileError(400, 'outside_root'),
    );
    expect(files.resolveExisting('docs/a.txt'), '${files.root}/docs/a.txt');
    expect(files.resolveExisting('inside-link'), '${files.root}/docs');
  });

  test(
    'list shows dirs first; a link out of the root is marked, not followed',
    () {
      final listing = files.list('');
      final entries = (listing['entries']! as List)
          .cast<Map<String, Object?>>();
      expect(entries.map((e) => '${e['name']}:${e['type']}'), [
        'docs:dir',
        'inside-link:dir',
        'escape:link',
      ]);
      expect(listing['parent'], isNull);
      final docs = files.list('docs');
      expect(docs['parent'], files.root);
      expect(((docs['entries']! as List).single as Map)['size'], 5);
      expect(() => files.list('docs/a.txt'), fileError(400, 'not_a_directory'));
    },
  );

  test(
    'upload in chunks, resume after a dropped chunk, rename into place',
    () async {
      final payload = List<int>.generate(10000, (i) => i % 251);
      final u = files.startUpload(
        dir: 'docs',
        name: 'b.bin',
        size: payload.length,
        overwrite: false,
        owner: 'me',
      );
      expect(File(u.target).existsSync(), isFalse);
      expect(
        await files.appendChunk(u, 0, Stream.value(payload.sublist(0, 4096))),
        4096,
      );

      // A chunk that breaks off half way keeps what arrived.
      final broken = StreamController<List<int>>();
      final pending = files.appendChunk(u, 4096, broken.stream);
      broken.add(payload.sublist(4096, 6000));
      broken.addError(const SocketException('connection reset'));
      await expectLater(pending, throwsA(isA<SocketException>()));
      expect(u.offset, 6000, reason: 'resume point = bytes received');

      // Wrong offset is refused; the right one continues.
      expect(
        () => files.appendChunk(u, 4096, Stream.value([1])),
        fileError(409, 'offset_mismatch'),
      );
      // Same target and size from the same login resumes the same upload.
      expect(
        files
            .startUpload(
              dir: 'docs',
              name: 'b.bin',
              size: payload.length,
              overwrite: false,
              owner: 'me',
            )
            .id,
        u.id,
      );
      expect(
        await files.appendChunk(
          u,
          6000,
          Stream.value(payload.sublist(6000, 10000)),
        ),
        10000,
      );
      expect(File(u.target).readAsBytesSync(), payload);
      expect(File(u.part).existsSync(), isFalse);
      expect(() => files.upload(u.id, 'me'), fileError(404, 'unknown_upload'));
    },
  );

  test(
    'upload rules: size, chunk size, names, overwrite, symlinks, owner',
    () async {
      expect(
        () => files.startUpload(
          dir: '',
          name: 'x',
          size: 2 * 1024 * 1024,
          overwrite: false,
          owner: 'me',
        ),
        fileError(413, 'too_large'),
      );
      expect(
        () => files.startUpload(
          dir: '',
          name: '../x',
          size: 1,
          overwrite: false,
          owner: 'me',
        ),
        fileError(400, 'bad_name'),
      );
      expect(
        () => files.startUpload(
          dir: '',
          name: '..',
          size: 1,
          overwrite: false,
          owner: 'me',
        ),
        fileError(400, 'bad_name'),
      );
      expect(
        () => files.startUpload(
          dir: '../',
          name: 'x',
          size: 1,
          overwrite: false,
          owner: 'me',
        ),
        fileError(400, 'outside_root'),
      );
      expect(
        () => files.startUpload(
          dir: 'docs',
          name: 'a.txt',
          size: 1,
          overwrite: false,
          owner: 'me',
        ),
        fileError(409, 'exists'),
      );
      expect(
        () => files.startUpload(
          dir: '',
          name: 'escape',
          size: 1,
          overwrite: true,
          owner: 'me',
        ),
        fileError(400, 'target_is_symlink'),
      );
      final u = files.startUpload(
        dir: 'docs',
        name: 'a.txt',
        size: 5000,
        overwrite: true,
        owner: 'me',
      );
      expect(
        () => files.upload(u.id, 'someone-else'),
        fileError(404, 'unknown_upload'),
      );
      await expectLater(
        files.appendChunk(u, 0, Stream.value(List.filled(4097, 1))),
        throwsA(isA<FileError>()),
      );
      files.cancel(u);
      expect(File(u.part).existsSync(), isFalse);
      expect(
        File('${home.path}/docs/a.txt').readAsStringSync(),
        'hello',
        reason: 'original untouched until complete',
      );
    },
  );
}
