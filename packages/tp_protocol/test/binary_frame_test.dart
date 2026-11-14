import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tp_protocol/tp_protocol.dart';

void main() {
  final sid = SessionId.random(Random(11));

  test('output frame layout matches docs/04', () {
    final frame = encodeOutputFrame(sid, 258, utf8.encode('hi'));
    expect(frame.length, 25 + 2);
    expect(frame[0], BinaryFrame.typeOutput);
    expect(frame.sublist(1, 17), sid.bytes);
    expect(frame.sublist(17, 25), [0, 0, 0, 0, 0, 0, 1, 2]);
    expect(frame.sublist(25), utf8.encode('hi'));
  });

  test('round-trips both directions, including seq beyond 32 bits', () {
    const big = 0x1F0000000005; // > 2^32, < 2^53 so it also works on the web
    final out = decodeBinaryFrame(encodeOutputFrame(sid, big, [1, 2, 3]));
    expect(out, isA<OutputFrame>());
    out as OutputFrame;
    expect(out.session, sid);
    expect(out.seq, big);
    expect(out.data, [1, 2, 3]);

    final input = decodeBinaryFrame(
      encodeInputFrame(sid, 77, utf8.encode('ls\r')),
    );
    expect(input, isA<InputFrame>());
    input as InputFrame;
    expect(input.clientMsgId, 77);
    expect(utf8.decode(input.data), 'ls\r');
  });

  test('empty payload is allowed', () {
    final f =
        decodeBinaryFrame(encodeOutputFrame(sid, 0, const [])) as OutputFrame;
    expect(f.data, isEmpty);
  });

  test('rejects short frames, reserved and unknown types, huge input', () {
    expect(
      () => decodeBinaryFrame(Uint8List(10)),
      throwsA(isA<ProtocolException>()),
    );
    final exec = encodeOutputFrame(sid, 1, [1])..[0] = BinaryFrame.typeExecOut;
    expect(() => decodeBinaryFrame(exec), throwsA(isA<ProtocolException>()));
    final unknown = encodeOutputFrame(sid, 1, [1])..[0] = 0x7f;
    expect(() => decodeBinaryFrame(unknown), throwsA(isA<ProtocolException>()));
    final huge = encodeInputFrame(
      sid,
      1,
      Uint8List(Limits.maxInputFrameBytes + 1),
    );
    expect(() => decodeBinaryFrame(huge), throwsA(isA<ProtocolException>()));
    expect(() => encodeOutputFrame(sid, -1, const []), throwsArgumentError);
  });
}
