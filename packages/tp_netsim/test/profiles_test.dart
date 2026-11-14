import 'package:test/test.dart';
import 'package:tp_netsim/tp_netsim.dart';

void main() {
  test('built-in profiles have unique names and resolve by name', () {
    final names = NetProfile.all.map((p) => p.name).toSet();
    expect(names, hasLength(NetProfile.all.length));
    for (final profile in NetProfile.all) {
      expect(NetProfile.byName(profile.name), same(profile));
    }
    expect(NetProfile.byName('nope'), isNull);
  });

  test('hostile blocks WebSockets and cuts idle connections', () {
    expect(NetProfile.hostile.blockWebSocketUpgrade, isTrue);
    expect(NetProfile.hostile.idleCutoff, const Duration(seconds: 45));
    expect(NetProfile.geo.blockWebSocketUpgrade, isFalse);
  });

  test('leo has scheduled outages, geo has none', () {
    expect(NetProfile.leo.outageEvery, isNotNull);
    expect(NetProfile.leo.outageDuration, const Duration(seconds: 5));
    expect(NetProfile.geo.outageEvery, isNull);
  });
}
