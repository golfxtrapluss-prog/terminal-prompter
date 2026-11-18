import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Registers the service worker that caches the client files (docs/16
/// "Installerbar app"). Silently does nothing where unsupported.
void registerServiceWorker() {
  try {
    final container = web.window.navigator.serviceWorker;
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
