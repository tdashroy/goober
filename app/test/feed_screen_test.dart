import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goober/src/api_client.dart';
import 'package:goober/src/models.dart';
import 'package:goober/src/screens/feed_screen.dart';
import 'package:goober/src/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

ApiClient _emptyFeedApi() {
  final client = MockClient((req) async {
    return http.Response(
      jsonEncode({'group_id': 'g1', 'group_name': 'Beach 2027', 'rides': []}),
      200,
    );
  });
  return ApiClient(baseUrl: 'http://test', client: client);
}

void main() {
  testWidgets('renders the empty feed state and the Get a ride button', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildGooberTheme(),
        home: FeedScreen(
          api: _emptyFeedApi(),
          session: _session(),
          onUnauthenticated: () {},
        ),
      ),
    );
    // Resolve the feed future.
    await tester.pumpAndSettle();

    // Friendly empty state.
    expect(find.byType(EmptyFeed), findsOneWidget);
    expect(find.text('All quiet on the boardwalk'), findsOneWidget);

    // The big "Get a ride" button is present.
    expect(find.byKey(const Key('get-a-ride-button')), findsOneWidget);
    expect(find.text('Get a ride'), findsOneWidget);

    // Group name in the app bar.
    expect(find.text('Beach 2027'), findsOneWidget);
  });

  testWidgets('Get a ride is a placeholder (shows coming-soon snackbar)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildGooberTheme(),
        home: FeedScreen(
          api: _emptyFeedApi(),
          session: _session(),
          onUnauthenticated: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('get-a-ride-button')));
    await tester.pump();

    expect(find.textContaining('coming soon'), findsOneWidget);
  });
}
