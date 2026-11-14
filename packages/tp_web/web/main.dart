import 'package:tp_web/tp_web.dart';
import 'package:web/web.dart';

/// Entry point of the browser client. Milestone M0: a placeholder page that
/// proves the dart2js build and the asset pipeline work end to end.
void main() {
  document.title = 'Terminal Prompter';
  final app = document.getElementById('app') ?? document.body!;

  final heading = document.createElement('h1')
    ..textContent = 'Terminal Prompter';
  final note = document.createElement('p')
    ..textContent =
        '${clientIdentifier()} - the terminal arrives in milestone M2.';

  app
    ..appendChild(heading)
    ..appendChild(note);
}
