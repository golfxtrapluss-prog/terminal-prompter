import 'dart:io';

/// Reads answers from the operator. Separate from `stdin` so tests can
/// script the conversation.
abstract interface class Console {
  /// Prompts and reads one line; [secret] turns echo off on a terminal.
  /// Returns null at end of input.
  String? ask(String prompt, {bool secret = false});
}

/// [Console] on the process's stdin/stdout.
final class StdConsole implements Console {
  const StdConsole();

  @override
  String? ask(String prompt, {bool secret = false}) {
    stdout.write(prompt);
    final terminal = stdin.hasTerminal;
    final echo = terminal ? stdin.echoMode : true;
    if (secret && terminal) stdin.echoMode = false;
    try {
      return stdin.readLineSync();
    } finally {
      if (secret && terminal) {
        stdin.echoMode = echo;
        stdout.writeln();
      }
    }
  }
}

/// [Console] answering from a list (tests).
final class ScriptedConsole implements Console {
  ScriptedConsole(List<String> answers) : _answers = List.of(answers);

  final List<String> _answers;
  final List<String> prompts = [];

  @override
  String? ask(String prompt, {bool secret = false}) {
    prompts.add(prompt);
    return _answers.isEmpty ? null : _answers.removeAt(0);
  }
}
