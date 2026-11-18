import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Keeps the app sized to the *visual* viewport so the key bar sits right
/// above the phone keyboard and follows it (docs/16). Falls back to `100dvh`
/// from CSS where `visualViewport` is unavailable.
final class ViewportManager {
  ViewportManager(this._app) {
    final vv = web.window.visualViewport;
    if (vv == null) return;
    final handler = ((web.Event _) => _apply(vv)).toJS;
    vv.addEventListener('resize', handler);
    vv.addEventListener('scroll', handler);
    _apply(vv);
  }

  final web.HTMLElement _app;

  /// True while the on-screen keyboard is likely open.
  bool keyboardOpen = false;

  /// Called after the layout changed.
  void Function()? onChange;

  void _apply(web.VisualViewport vv) {
    final height = vv.height;
    final layoutHeight = web.window.innerHeight;
    keyboardOpen = layoutHeight - height > 120;
    _app.style.height = '${height}px';
    _app.style.transform = 'translateY(${vv.offsetTop}px)';
    // Keep the document itself from scrolling under the keyboard.
    web.window.scrollTo(web.ScrollToOptions(top: 0, left: 0));
    onChange?.call();
  }
}
