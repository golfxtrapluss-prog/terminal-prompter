import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/embed_assets.dart';

void main() {
  test('empty input yields a valid, empty const map', () {
    final src = generateAssetSource({});
    expect(src, contains('const Map<String, EmbeddedAsset> embeddedAssets'));
    expect(src, isNot(contains('EmbeddedAsset(')));
    expect(src, contains('// dart format off'));
  });

  test('assets are sorted, typed and round-trip through gzip+base64', () {
    final css = utf8.encode('body { color: red; }');
    final html = utf8.encode('<!doctype html><title>x</title>');
    final src = generateAssetSource({
      'index.html': html,
      'assets/styles.css': css,
    });

    expect(
      src.indexOf("'assets/styles.css'"),
      lessThan(src.indexOf("'index.html'")),
    );
    expect(src, contains("contentType: 'text/css; charset=utf-8'"));
    expect(src, contains('rawLength: ${css.length},'));

    final start = src.indexOf("'index.html': EmbeddedAsset(");
    final block = src.substring(start, src.indexOf('  ),', start));
    final b64 = RegExp(r"^\s+'([A-Za-z0-9+/=]*)'", multiLine: true)
        .allMatches(block.substring(block.indexOf('gzipBase64:')))
        .map((m) => m.group(1)!)
        .join();
    expect(gzip.decode(base64Decode(b64)), html);
  });

  test('content types fall back to octet-stream', () {
    expect(contentTypeFor('a/b/main.dart.js'), startsWith('text/javascript'));
    expect(contentTypeFor('x.WOFF2'), 'font/woff2');
    expect(contentTypeFor('blob.bin'), 'application/octet-stream');
  });

  test('paths with quotes are escaped', () {
    final src = generateAssetSource({"it's.txt": utf8.encode('x')});
    expect(src, contains(r"'it\'s.txt': EmbeddedAsset("));
  });
}
