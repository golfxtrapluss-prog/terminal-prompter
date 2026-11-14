import 'package:args/command_runner.dart';
import 'package:test/test.dart';
import 'package:tp_agent/tp_agent.dart';
import 'package:tp_protocol/tp_protocol.dart';

void main() {
  late StringBuffer out;
  late StringBuffer err;
  late CommandRunner<int> runner;

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();
    runner = buildRunner(out: out, err: err);
  });

  test('version prints build version and protocol version', () async {
    final code = await runner.run(['version']);
    expect(code, 0);
    expect(
      out.toString().trim(),
      'tp-agent $tpVersion (protocol v$protocolVersion)',
    );
    expect(err.toString(), isEmpty);
  });

  test('run with a missing config file fails with EX_CONFIG', () async {
    final code = await runner.run(['run', '--config', '/nonexistent/x.toml']);
    expect(code, 78);
    expect(err.toString(), contains('/nonexistent/x.toml'));
  });

  test('unknown command raises a usage error', () {
    expect(() => runner.run(['bogus']), throwsA(isA<UsageException>()));
  });
}
