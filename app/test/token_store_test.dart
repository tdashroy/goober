import 'package:flutter_test/flutter_test.dart';
import 'package:goober/src/models.dart';
import 'package:goober/src/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Session _session() => const Session(
  token: 'tok-abc',
  groupId: 'g1',
  groupName: 'Beach 2027',
  member: Member(
    id: 'm1',
    groupId: 'g1',
    displayName: 'Troy',
    phone: '5551112222',
    isAdmin: true,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedPrefsTokenStore', () {
    test('read returns null when nothing is persisted', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SharedPrefsTokenStore(
        prefs: await SharedPreferences.getInstance(),
      );
      expect(await store.read(), isNull);
    });

    test('save then read round-trips the session', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SharedPrefsTokenStore(
        prefs: await SharedPreferences.getInstance(),
      );

      await store.save(_session());
      final restored = await store.read();

      expect(restored, isNotNull);
      expect(restored!.token, 'tok-abc');
      expect(restored.groupId, 'g1');
      expect(restored.groupName, 'Beach 2027');
      expect(restored.member.displayName, 'Troy');
      expect(restored.member.isAdmin, true);
    });

    test('clear removes the persisted session', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SharedPrefsTokenStore(
        prefs: await SharedPreferences.getInstance(),
      );
      await store.save(_session());

      await store.clear();

      expect(await store.read(), isNull);
    });
  });

  group('InMemoryTokenStore', () {
    test('round-trips and clears', () async {
      final store = InMemoryTokenStore();
      expect(await store.read(), isNull);
      await store.save(_session());
      expect((await store.read())!.token, 'tok-abc');
      await store.clear();
      expect(await store.read(), isNull);
    });
  });
}
