/// Prints an argon2id PHC hash for a password read from stdin. Used to
/// create dev/config.toml; production uses `tp-agent init`/`passwd`.
library;

import 'dart:io';

import 'package:tp_agent/src/auth/password.dart';

void main() {
  final password = stdin.readLineSync() ?? '';
  stdout.writeln(hashPassword(password));
}
