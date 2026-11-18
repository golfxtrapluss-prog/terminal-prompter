import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math';

import 'package:web/web.dart' as web;

import '../api_client.dart';
import '../i18n/strings.dart';
import 'dom.dart';

/// File browser (docs/02, docs/03 "⬆ last opp ⬇ last ned"): browse within
/// `files.root`, download with the browser, upload in chunks that resume
/// automatically after a dropped link.
final class FilesPanel {
  FilesPanel({required this.api, required this.strings}) {
    element = el('aside', className: 'settings files hidden');
  }

  final ApiClient api;
  final Strings strings;
  late final web.HTMLElement element;
  String _path = '';
  int _chunkSize = 256 * 1024;
  final Map<String, web.HTMLElement> _uploads = {};

  bool get isOpen => !element.classList.contains('hidden');

  void close() => element.classList.add('hidden');

  Future<void> open() async {
    element.classList.remove('hidden');
    await _load(_path);
  }

  Future<void> _load(String path) async {
    element.textContent = '';
    final header = el('div', className: 'panel-header');
    final closeBtn = el('button', text: '×', label: strings['settings.close']);
    closeBtn.onclick = ((web.Event _) => close()).toJS;
    header
      ..appendChild(el('h2', text: strings['files']))
      ..appendChild(closeBtn);
    element.appendChild(header);

    final Map<String, Object?> listing;
    try {
      listing = await api.get(
        'files/list?path=${Uri.encodeQueryComponent(path)}',
      );
    } on ApiException catch (e) {
      element.appendChild(
        el(
          'p',
          className: 'settings-error',
          text: '${strings['files.error']}: ${e.code}',
        ),
      );
      if (path.isNotEmpty) {
        final home = el('button', text: strings['files.home']);
        home.onclick = ((web.Event _) => _load('')).toJS;
        element.appendChild(home);
      }
      return;
    }
    _path = listing['path']! as String;
    _chunkSize = (listing['chunk_size'] as int?) ?? _chunkSize;
    final root = listing['root']! as String;
    final parent = listing['parent'] as String?;

    element.appendChild(
      el(
        'div',
        className: 'files-path',
        text: _path == root ? '~' : '~${_path.substring(root.length)}',
      ),
    );

    final actions = el('div', className: 'settings-actions');
    if (parent != null) {
      final up = el('button', text: '⬆ ..');
      up.onclick = ((web.Event _) => _load(parent)).toJS;
      actions.appendChild(up);
    }
    final input = el('input') as web.HTMLInputElement
      ..type = 'file'
      ..multiple = true
      ..className = 'hidden';
    final upload = el(
      'button',
      className: 'primary',
      text: '⬆ ${strings['files.upload']}',
    );
    upload.onclick = ((web.Event _) => input.click()).toJS;
    input.onchange = ((web.Event _) {
      final list = input.files;
      if (list == null) return;
      for (var i = 0; i < list.length; i++) {
        final f = list.item(i);
        if (f != null) unawaited(_upload(f, _path));
      }
      input.value = '';
    }).toJS;
    actions
      ..appendChild(upload)
      ..appendChild(input);
    element.appendChild(actions);

    final progress = el('div', className: 'files-progress');
    _uploads.forEach((_, row) => progress.appendChild(row));
    element.appendChild(progress);

    final list = el('div', className: 'files-list');
    for (final e
        in (listing['entries']! as List).cast<Map<String, Object?>>()) {
      final name = e['name']! as String;
      final type = e['type']! as String;
      final full = '$_path/$name';
      final row = el('div', className: 'file-row');
      if (type == 'dir') {
        final open = el('button', className: 'file-name', text: '📁 $name');
        open.onclick = ((web.Event _) => _load(full)).toJS;
        row.appendChild(open);
      } else if (type == 'file') {
        final a =
            el('a', className: 'file-name', text: '📄 $name')
                  as web.HTMLAnchorElement
              ..href =
                  '${api.base}api/files/download?path=${Uri.encodeQueryComponent(full)}'
              ..download = name;
        row
          ..appendChild(a)
          ..appendChild(
            el('span', className: 'muted', text: _size(e['size'] as int? ?? 0)),
          );
      } else {
        row.appendChild(
          el('span', className: 'file-name muted', text: '🔗 $name'),
        );
      }
      list.appendChild(row);
    }
    element.appendChild(list);
  }

  /// Uploads [file] into [dir] in chunks; on any failure asks the agent how
  /// far it got (HEAD) and continues from there with backoff.
  Future<void> _upload(web.File file, String dir) async {
    final key = '${file.name}-${DateTime.now().microsecondsSinceEpoch}';
    final row = el('div', className: 'upload-row');
    final label = el('span', text: file.name);
    final bar = el('progress') as web.HTMLProgressElement
      ..max = max(file.size, 1).toDouble()
      ..value = 0;
    final status = el('span', className: 'muted', text: '');
    row
      ..appendChild(label)
      ..appendChild(bar)
      ..appendChild(status);
    _uploads[key] = row;
    element.querySelector('.files-progress')?.appendChild(row);

    try {
      Map<String, Object?> start;
      try {
        start = await api.post('files/upload', {
          'dir': dir,
          'name': file.name,
          'size': file.size,
        });
      } on ApiException catch (e) {
        if (e.code != 'exists' ||
            !web.window.confirm(
              '${file.name}: ${strings['files.overwrite']}',
            )) {
          rethrow;
        }
        start = await api.post('files/upload', {
          'dir': dir,
          'name': file.name,
          'size': file.size,
          'overwrite': true,
        });
      }
      final id = start['id']! as String;
      var offset = start['offset'] as int? ?? 0;
      var failures = 0;
      while (offset < file.size) {
        bar.value = offset.toDouble();
        status.textContent = '${(offset * 100 / file.size).floor()} %';
        final end = min(offset + _chunkSize, file.size);
        try {
          offset = await _sendChunk(id, offset, file.slice(offset, end));
          failures = 0;
        } on Object {
          failures++;
          if (failures > 30) rethrow;
          status.textContent = strings['files.retrying'];
          await Future<void>.delayed(
            Duration(milliseconds: min(10000, 500 * (1 << min(failures, 5)))),
          );
          offset = await _offset(id) ?? offset;
        }
      }
      bar.value = file.size.toDouble();
      status.textContent = '✓';
      Timer(const Duration(seconds: 3), () {
        _uploads.remove(key);
        row.remove();
      });
      if (isOpen && dir == _path) unawaited(_load(_path));
    } on ApiException catch (e) {
      status.textContent = '✗ ${e.code}';
    } on Object {
      status.textContent = '✗ ${strings['files.error']}';
    }
  }

  Future<int> _sendChunk(String id, int offset, web.Blob chunk) async {
    final headers = web.Headers()
      ..set('Content-Type', 'application/octet-stream')
      ..set('Upload-Offset', '$offset');
    final csrf = ApiClient.csrfToken();
    if (csrf != null) headers.set('X-TP-CSRF', csrf);
    final response = await web.window
        .fetch(
          '${api.base}api/files/upload/$id'.toJS,
          web.RequestInit(
            method: 'POST',
            headers: headers,
            body: chunk,
            credentials: 'same-origin',
          ),
        )
        .toDart;
    final now = int.tryParse(response.headers.get('Upload-Offset') ?? '');
    if (response.status == 409 && now != null) return now;
    if (!response.ok) {
      final text = (await response.text().toDart).toDart;
      final code = (jsonDecode(text.isEmpty ? '{}' : text) as Map)['error'];
      throw ApiException(
        response.status,
        code is String ? code : 'http_${response.status}',
      );
    }
    return now ?? offset;
  }

  Future<int?> _offset(String id) async {
    try {
      final response = await web.window
          .fetch(
            '${api.base}api/files/upload/$id'.toJS,
            web.RequestInit(method: 'HEAD', credentials: 'same-origin'),
          )
          .toDart;
      return int.tryParse(response.headers.get('Upload-Offset') ?? '');
    } on Object {
      return null;
    }
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}
