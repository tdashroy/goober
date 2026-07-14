import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goober/main.dart';
import 'package:goober/src/api_client.dart';
import 'package:goober/src/dev_login.dart';
import 'package:goober/src/models.dart';
import 'package:goober/src/screens/feed_screen.dart';
import 'package:goober/src/screens/onboarding_screen.dart';
import 'package:goober/src/token_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A MockClient standing in for a seeded dev server: it answers
/// `/dev/session/{key}` for the people the beach-trip seed profile creates, and
/// serves that group's feed.
ApiClient _seededServer() {
  final client = MockClient((req) async {
    if (req.method == 'GET' && req.url.path == '/dev/session/bob') {
      return http.Response(
        jsonEncode({
          'token': 'devseed-bob',
          'group_id': 'beach-trip',
          'group_name': 'Beach 2027',
          'member': {
            'id': 'beach-trip-bob',
            'group_id': 'beach-trip',
            'display_name': 'Uncle Bob',
            'phone': '+15550100002',
            'is_admin': false,
          },
        }),
        200,
      );
    }
    if (req.method == 'GET' && req.url.path.endsWith('/feed')) {
      return http.Response(
        jsonEncode({
          'group_id': 'beach-trip',
          'group_name': 'Beach 2027',
          'rides': <dynamic>[],
        }),
        200,
      );
    }
    return http.Response(jsonEncode({'error': 'seeded member not found'}), 404);
  });
  return ApiClient(baseUrl: 'http://test', client: client);
}

/// A server with no seed loaded (or no dev-seed build at all): the dev sign-in
/// route resolves nobody.
ApiClient _unseededServer() {
  final client = MockClient(
    (req) async => http.Response(jsonEncode({'error': 'not found'}), 404),
  );
  return ApiClient(baseUrl: 'http://test', client: client);
}

Session _staleSession() => const Session(
  token: 'tok-stale',
  groupId: 'g-old',
  groupName: 'Last Year',
  member: Member(
    id: 'm-old',
    groupId: 'g-old',
    displayName: 'Someone Else',
    phone: '5551112222',
    isAdmin: false,
  ),
);

void main() {
  group('the client-profile gate', () {
    test('a debug build honors the profile it was launched with', () {
      final dev = DevLogin.resolve(profile: 'bob', debugBuild: true);
      expect(dev, isNotNull);
      expect(dev!.memberKey, 'bob');
    });

    test('a release build refuses the profile entirely', () {
      // The auth bypass must be impossible in a shipped app: even handed a valid
      // profile, a non-debug build resolves no dev login at all. In a real
      // release build this is not merely false but const-folded away, so the
      // sign-in path is not even compiled in.
      expect(DevLogin.resolve(profile: 'bob', debugBuild: false), isNull);
      expect(DevLogin.resolve(profile: 'grandma', debugBuild: false), isNull);
    });

    test('no profile means a normal boot, even in debug', () {
      expect(DevLogin.resolve(profile: '', debugBuild: true), isNull);
      expect(DevLogin.resolve(profile: '   ', debugBuild: true), isNull);
    });
  });

  testWidgets(
    'a client profile boots straight into the seeded group, signed in '
    'as that person',
    (tester) async {
      final store = InMemoryTokenStore();
      await tester.pumpWidget(
        GooberApp(
          api: _seededServer(),
          tokenStore: store,
          devLogin: const DevLogin('bob'),
        ),
      );
      await tester.pumpAndSettle();

      // No login screen — we are on the seeded group's feed.
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(FeedScreen), findsOneWidget);
      expect(find.text('Beach 2027'), findsOneWidget);

      // ...as Uncle Bob, holding his real token.
      final saved = await store.read();
      expect(saved, isNotNull);
      expect(saved!.token, 'devseed-bob');
      expect(saved.member.displayName, 'Uncle Bob');
      expect(saved.groupId, 'beach-trip');
    },
  );

  testWidgets('the client profile wins over a token left on the device', (
    tester,
  ) async {
    // Relaunching an emulator as a different relative must actually switch
    // relative, not resurrect whoever was signed in last.
    final store = InMemoryTokenStore();
    await store.save(_staleSession());

    await tester.pumpWidget(
      GooberApp(
        api: _seededServer(),
        tokenStore: store,
        devLogin: const DevLogin('bob'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Beach 2027'), findsOneWidget);
    expect(find.text('Last Year'), findsNothing);
    expect((await store.read())!.token, 'devseed-bob');
  });

  testWidgets('an unseeded server falls back to the normal login flow', (
    tester,
  ) async {
    final store = InMemoryTokenStore();
    await tester.pumpWidget(
      GooberApp(
        api: _unseededServer(),
        tokenStore: store,
        devLogin: const DevLogin('bob'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(await store.read(), isNull);
  });

  testWidgets('a failed dev sign-in leaves a diagnostic trace, not silence', (
    tester,
  ) async {
    // The whole bug this guards against is a broken dev harness falling back to
    // onboarding without a word. The fallback itself is fine — the silence is
    // not. Capture debugPrint and prove the failure is now named.
    final printed = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) printed.add(message);
    };

    final store = InMemoryTokenStore();
    await tester.pumpWidget(
      GooberApp(
        api: _unseededServer(),
        tokenStore: store,
        devLogin: const DevLogin('bob'),
      ),
    );
    await tester.pumpAndSettle();
    // Restore before the body returns: the test binding asserts no foundation
    // debug variable is left reassigned at end of test.
    debugPrint = original;

    // Still falls back to onboarding (behaviour unchanged)...
    expect(find.byType(OnboardingScreen), findsOneWidget);
    // ...but now says so, naming the person it failed to sign in as.
    expect(
      printed.any((m) => m.contains('dev sign-in as "bob" failed')),
      isTrue,
      reason:
          'expected a diagnostic naming the failed dev sign-in, got: $printed',
    );
  });

  testWidgets('with no client profile the boot flow is untouched', (
    tester,
  ) async {
    final store = InMemoryTokenStore();
    await tester.pumpWidget(GooberApp(api: _seededServer(), tokenStore: store));
    await tester.pumpAndSettle();

    // Nothing was signed in behind our back.
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(await store.read(), isNull);
  });
}
