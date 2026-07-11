import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goober/src/api_client.dart';
import 'package:goober/src/models.dart';
import 'package:goober/src/screens/admin_screen.dart';
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

/// Serves an empty places list to whatever the admin screen opens.
ApiClient _api() {
  final client = MockClient((req) async {
    return http.Response(jsonEncode({'group_id': 'g1', 'places': []}), 200);
  });
  return ApiClient(baseUrl: 'http://test', client: client);
}

Widget _harness() => MaterialApp(
  theme: buildGooberTheme(),
  home: AdminScreen(api: _api(), session: _session()),
);

void main() {
  testWidgets('names the admin actions and says the area is admin-only', (
    tester,
  ) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.text('Admin'), findsOneWidget); // app bar title
    expect(find.textContaining('Only you see these controls'), findsOneWidget);

    // The admin actions are listed by name, not hidden behind icons.
    expect(find.byKey(const Key('manage-places-action')), findsOneWidget);
    expect(find.text('Manage places'), findsOneWidget);
  });

  testWidgets('Manage places opens the places screen', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('manage-places-action')));
    await tester.pumpAndSettle();

    // The places screen, with its own add affordance for the admin.
    expect(find.text('Places'), findsOneWidget);
    expect(find.byKey(const Key('add-place-button')), findsOneWidget);
  });
}
