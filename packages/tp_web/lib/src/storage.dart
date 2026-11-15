import 'package:web/web.dart' as web;

import 'conn/transport.dart';

/// `localStorage` wrapper that never throws (private mode, blocked storage,
/// quota). Values are per origin, so per agent (docs/03).
final class BrowserStorage implements KeyValueStore {
  const BrowserStorage();

  @override
  String? read(String key) {
    try {
      return web.window.localStorage.getItem(key);
    } on Object {
      return null; // Storage blocked by the browser; behave as if empty.
    }
  }

  @override
  void write(String key, String value) {
    try {
      web.window.localStorage.setItem(key, value);
    } on Object {
      // Storage blocked or full; the value is a convenience only.
    }
  }

  @override
  void remove(String key) {
    try {
      web.window.localStorage.removeItem(key);
    } on Object {
      // Nothing to do.
    }
  }
}
