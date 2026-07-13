import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goober/src/api_client.dart';
import 'package:goober/src/models.dart';
import 'package:goober/src/screens/admin_screen.dart';
import 'package:goober/src/screens/manage_places_screen.dart';
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

/// Serves an empty places list to whatever the admin screen opens, as UTF-8
/// bytes under a bare `application/json` (no charset), which is what axum
/// sends.
ApiClient _api() {
  final client = MockClient((req) async {
    return http.Response.bytes(
      utf8.encode(jsonEncode({'group_id': 'g1', 'places': []})),
      200,
      headers: {'content-type': 'application/json'},
    );
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

  testWidgets('Manage places opens places management', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('manage-places-action')));
    await tester.pumpAndSettle();

    // The management screen, with the admin's editing affordances.
    expect(find.byType(ManagePlacesScreen), findsOneWidget);
    expect(find.byKey(const Key('add-place-button')), findsOneWidget);
  });
}
