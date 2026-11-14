import 'package:test/test.dart';
import 'package:tp_protocol/tp_protocol.dart';

void main() {
  test('protocol version is supported', () {
    expect(minSupportedProtocolVersion, lessThanOrEqualTo(protocolVersion));
  });

  test('binary frame header is type + session id + 64-bit seq', () {
    expect(BinaryFrame.headerLength, 25);
    expect({
      BinaryFrame.typeOutput,
      BinaryFrame.typeInput,
      BinaryFrame.typeExecOut,
    }, hasLength(3));
  });

  test('heartbeat fits under proxy idle cut-offs and dead timeout', () {
    expect(Limits.heartbeat, lessThan(const Duration(seconds: 30)));
    expect(Limits.deadAfter, greaterThan(Limits.heartbeat));
    expect(Limits.ackEveryBytes, lessThan(Limits.maxUnackedOutputBytes));
  });
}
