import 'package:web/web.dart' as web;

/// `localStorage` wrapper that never throws (private mode, blocked storage,
/// quota). Values are per origin, so per agent (docs/03).
final class Storage {
  const Storage();

  /// Reads [key], or null when missing or storage is unavailable.
  String? read(String key) {
    try {
      return web.window.localStorage.getItem(key);
    } on Object {
      return null; // Storage blocked by the browser; behave as if empty.
    }
  }

  /// Writes [key]; silently ignored when storage is unavailable.
  void write(String key, String value) {
    try {
      web.window.localStorage.setItem(key, value);
    } on Object {
      // Storage blocked or full; the value is a convenience only.
    }
  }

  /// Removes [key]; silently ignored when storage is unavailable.
  void remove(String key) {
    try {
      web.window.localStorage.removeItem(key);
    } on Object {
      // Nothing to do.
    }
  }
}
