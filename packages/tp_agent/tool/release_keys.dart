/// Generates a release signing key pair.
///
/// Prints the private seed (keep it secret: store it as the CI secret
/// `TP_RELEASE_SIGNING_KEY`) and the public key (pass it to builds as
/// `make build TP_RELEASE_KEY=...` and publish it).
library;

import 'dart:convert';
import 'dart:io';

import 'package:tp_agent/src/update/release.dart';

Future<void> main() async {
  final seed = newSigningSeed();
  stdout
    ..writeln('TP_RELEASE_SIGNING_KEY=${base64Encode(seed)}   # SECRET')
    ..writeln('TP_RELEASE_KEY=${await publicKeyForSeed(seed)}   # public');
}
