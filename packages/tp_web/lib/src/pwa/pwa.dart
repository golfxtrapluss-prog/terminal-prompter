import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Registers the service worker that caches the client files (docs/16
/// "Installerbar app"). Silently does nothing where unsupported.
///
/// When an updated worker takes control of a page that was already
/// controlled by an older one, the page reloads once so it runs the new
/// client code instead of the cached old build (the agent was updated).
void registerServiceWorker() {
  try {
    final container = web.window.navigator.serviceWorker;
    final hadController = container.controller != null;
    var reloaded = false;
    container.addEventListener(
      'controllerchange',
      ((web.Event _) {
        if (!hadController || reloaded) return;
        reloaded = true;
        web.window.location.reload();
      }).toJS,
    );
    container
        .register('sw.js'.toJS)
        .toDart
        .then(
          (_) {},
          onError: (Object _) {
            // Registration failures (e.g. http on a LAN IP) are not fatal.
          },
        );
  } on Object {
    // No service worker support.
  }
}

/// True when running as an installed app.
bool get isStandalone =>
    web.window.matchMedia('(display-mode: standalone)').matches;
