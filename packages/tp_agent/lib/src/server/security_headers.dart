import 'dart:io';

/// Content-Security-Policy for the web client (docs/05). dart2js output does
/// not need `unsafe-eval`; xterm.js sets inline style attributes.
const String contentSecurityPolicy =
    "default-src 'self'; connect-src 'self'; "
    "img-src 'self' data:; style-src 'self' 'unsafe-inline'; "
    "frame-ancestors 'none'";

/// Applies the security headers from docs/05 to every response.
void applySecurityHeaders(HttpResponse response, {required bool hsts}) {
  final h = response.headers;
  h.set('Content-Security-Policy', contentSecurityPolicy);
  h.set('X-Content-Type-Options', 'nosniff');
  h.set('X-Frame-Options', 'DENY');
  h.set('Referrer-Policy', 'no-referrer');
  h.set('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  h.removeAll('X-XSS-Protection');
  if (hsts) h.set('Strict-Transport-Security', 'max-age=31536000');
}
