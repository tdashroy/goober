import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Persists the bearer token + which group it belongs to across app launches.
///
/// An abstract interface so tests can substitute an in-memory implementation and
/// exercise the persistence logic without touching platform storage.
abstract class TokenStore {
  Future<Session?> read();
  Future<void> save(Session session);
  Future<void> clear();
}

/// Production store backed by `shared_preferences` (Android `SharedPreferences`).
class SharedPrefsTokenStore implements TokenStore {
  SharedPrefsTokenStore({SharedPreferences? prefs}) : _injected = prefs;

  static const _kToken = 'goober.token';
  static const _kGroupId = 'goober.group_id';
  static const _kGroupName = 'goober.group_name';
  static const _kMemberId = 'goober.member_id';
  static const _kDisplayName = 'goober.display_name';
  static const _kPhone = 'goober.phone';
  static const _kIsAdmin = 'goober.is_admin';

  final SharedPreferences? _injected;

  Future<SharedPreferences> get _prefs async =>
      _injected ?? await SharedPreferences.getInstance();

  @override
  Future<Session?> read() async {
    final p = await _prefs;
    final token = p.getString(_kToken);
    final groupId = p.getString(_kGroupId);
    final memberId = p.getString(_kMemberId);
    if (token == null || groupId == null || memberId == null) return null;
    return Session(
      token: token,
      groupId: groupId,
      groupName: p.getString(_kGroupName) ?? '',
      member: Member(
        id: memberId,
        groupId: groupId,
        displayName: p.getString(_kDisplayName) ?? '',
        phone: p.getString(_kPhone) ?? '',
        isAdmin: p.getBool(_kIsAdmin) ?? false,
      ),
    );
  }

  @override
  Future<void> save(Session s) async {
    final p = await _prefs;
    await p.setString(_kToken, s.token);
    await p.setString(_kGroupId, s.groupId);
    await p.setString(_kGroupName, s.groupName);
    await p.setString(_kMemberId, s.member.id);
    await p.setString(_kDisplayName, s.member.displayName);
    await p.setString(_kPhone, s.member.phone);
    await p.setBool(_kIsAdmin, s.member.isAdmin);
  }

  @override
  Future<void> clear() async {
    final p = await _prefs;
    for (final key in [
      _kToken,
      _kGroupId,
      _kGroupName,
      _kMemberId,
      _kDisplayName,
      _kPhone,
      _kIsAdmin,
    ]) {
      await p.remove(key);
    }
  }
}

/// In-memory store for tests.
class InMemoryTokenStore implements TokenStore {
  Session? _session;

  @override
  Future<Session?> read() async => _session;

  @override
  Future<void> save(Session session) async => _session = session;

  @override
  Future<void> clear() async => _session = null;
}
