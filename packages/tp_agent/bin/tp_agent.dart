import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:tp_agent/tp_agent.dart';

Future<void> main(List<String> args) async {
  final runner = buildRunner(out: stdout, err: stderr);
  try {
    exitCode = await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  }
  await stdout.flush();
  await stderr.flush();
}
