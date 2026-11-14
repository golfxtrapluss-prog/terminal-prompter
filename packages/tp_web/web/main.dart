import 'package:tp_web/tp_web.dart';
import 'package:web/web.dart' as web;

/// Entry point of the browser client.
void main() {
  final root = web.document.getElementById('app') as web.HTMLElement?;
  App(root ?? web.document.body!).run();
}
