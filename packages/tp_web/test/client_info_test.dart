import 'package:test/test.dart';
import 'package:tp_protocol/tp_protocol.dart';
import 'package:tp_web/tp_web.dart';

void main() {
  test('client identifier carries version and protocol version', () {
    final id = clientIdentifier();
    expect(id, startsWith('tp_web/'));
    expect(id, contains(clientVersion));
    expect(id, contains('protocol v$protocolVersion'));
  });
}
