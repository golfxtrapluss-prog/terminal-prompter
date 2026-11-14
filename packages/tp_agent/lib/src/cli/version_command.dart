import 'package:args/command_runner.dart';
import 'package:tp_protocol/tp_protocol.dart';

import '../version.dart';

/// `tp-agent version`: prints the build version and protocol version.
final class VersionCommand extends Command<int> {
  /// Creates the command writing to [_out].
  VersionCommand(this._out);

  final StringSink _out;

  @override
  String get name => 'version';

  @override
  String get description => 'Print the agent version.';

  @override
  Future<int> run() async {
    _out.writeln('tp-agent $tpVersion (protocol v$protocolVersion)');
    return 0;
  }
}
