import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goober/main.dart';
import 'package:goober/src/api_client.dart';
import 'package:goober/src/models.dart';
import 'package:goober/src/screens/feed_screen.dart';
import 'package:goober/src/screens/onboarding_screen.dart';
import 'package:goober/src/token_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A MockClient that answers create-group and feed calls like the real server.
ApiClient _fakeServer() {
  final client = MockClient((req) async {
    if (req.method == 'POST' && req.url.path == '/groups') {
      return http.Response(
        jsonEncode({
          'token': 'tok-new',
          'group_id': 'g1',
          'group_name': 'Beach 2027',
          'member': {
            'id': 'm1',
            'group_id': 'g1',
            'display_name': 'Troy',
            'phone': '5551112222',
            'is_admin': true,
          },
        }),
        200,
      );
    }
    if (req.method == 'GET' && req.url.path.endsWith('/feed')) {
      return http.Response(
        jsonEncode({'group_id': 'g1', 'group_name': 'Beach 2027', 'rides': []}),
        200,
      );
    }
    return http.Response('not found', 404);
  });
  return ApiClient(baseUrl: 'http://test', client: client);
}

/// A MockClient whose feed endpoint rejects the persisted token with a 401,
/// as happens when the server DB has been wiped out from under a stale token.
ApiClient _staleTokenServer() {
  final client = MockClient((req) async {
    if (req.method == 'GET' && req.url.path.endsWith('/feed')) {
      return http.Response(jsonEncode({'error': 'invalid token'}), 401);
    }
    return http.Response('not found', 404);
  });
  return ApiClient(baseUrl: 'http://test', client: client);
}

Session _persistedSession() => const Session(
  token: 'tok-existing',
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
  testWidgets(
    'fresh boot shows onboarding, then persists token and shows feed',
    (tester) async {
      final store = InMemoryTokenStore();
      await tester.pumpWidget(GooberApp(api: _fakeServer(), tokenStore: store));
      await tester.pumpAndSettle();

      // No token yet → onboarding.
      expect(find.byType(OnboardingScreen), findsOneWidget);

      // Fill the form and start the trip.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Trip name'),
        'Beach 2027',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Your name'),
        'Troy',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Phone number'),
        '555-111-2222',
      );

      await tester.tap(find.byKey(const Key('create-group-button')));
      await tester.pumpAndSettle();

      // We are now on the feed with its empty state...
      expect(find.byType(FeedScreen), findsOneWidget);
      expect(find.byType(EmptyFeed), findsOneWidget);
      expect(find.byKey(const Key('get-a-ride-button')), findsOneWidget);

      // ...and the token was persisted.
      final saved = await store.read();
      expect(saved, isNotNull);
      expect(saved!.token, 'tok-new');
    },
  );

  testWidgets('boot with a persisted token goes straight to the feed', (
    tester,
  ) async {
    final store = InMemoryTokenStore();
    await store.save(_persistedSession());

    await tester.pumpWidget(GooberApp(api: _fakeServer(), tokenStore: store));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.byType(FeedScreen), findsOneWidget);
    expect(find.byType(EmptyFeed), findsOneWidget);
  });

  testWidgets('a 401 on the feed clears the token and returns to onboarding', (
    tester,
  ) async {
    final store = InMemoryTokenStore();
    await store.save(_persistedSession());

    await tester.pumpWidget(
      GooberApp(api: _staleTokenServer(), tokenStore: store),
    );
    await tester.pumpAndSettle();

    // The stale token is rejected → back to onboarding, not stuck on the feed.
    expect(find.byType(FeedScreen), findsNothing);
    expect(find.byType(OnboardingScreen), findsOneWidget);

    // ...and the bad token was cleared so we don't loop back into it on boot.
    expect(await store.read(), isNull);
  });
}
