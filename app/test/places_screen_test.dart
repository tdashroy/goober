import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goober/src/api_client.dart';
import 'package:goober/src/models.dart';
import 'package:goober/src/screens/places_screen.dart';
import 'package:goober/src/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Session _session({required bool isAdmin}) => Session(
  token: 'tok-abc',
  groupId: 'g1',
  groupName: 'Beach 2027',
  member: Member(
    id: 'm1',
    groupId: 'g1',
    displayName: 'Troy',
    phone: '5551112222',
    isAdmin: isAdmin,
  ),
);

/// A place JSON blob.
Map<String, dynamic> _place(String id, String name, double lat, double lng) => {
  'id': id,
  'group_id': 'g1',
  'name': name,
  'lat': lat,
  'lng': lng,
};

/// A response shaped like the server's: UTF-8 bytes under a bare
/// `application/json` (no charset), which is what axum sends.
http.Response _json(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: {'content-type': 'application/json'},
);

/// Serves [places], and records every request so a test can assert the screen
/// only ever reads.
ApiClient _api(List<Map<String, dynamic>> places, {List<http.Request>? log}) {
  final client = MockClient((req) async {
    log?.add(req);
    return _json({'group_id': 'g1', 'places': places});
  });
  return ApiClient(baseUrl: 'http://test', client: client);
}

Widget _harness(ApiClient api, {required bool isAdmin}) => MaterialApp(
  theme: buildGooberTheme(),
  home: PlacesScreen(
    api: api,
    session: _session(isAdmin: isAdmin),
  ),
);

void main() {
  testWidgets('lists the group places with where they are', (tester) async {
    final api = _api([
      _place('p1', "Grandma's", 38.8, -75.0),
      _place('p2', 'The Pier', 38.9, -75.1),
    ]);
    await tester.pumpWidget(_harness(api, isAdmin: false));
    await tester.pumpAndSettle();

    expect(find.text("Grandma's"), findsOneWidget);
    expect(find.text('The Pier'), findsOneWidget);
    expect(find.text('38.80000, -75.00000'), findsOneWidget);
  });

  testWidgets('offers a member no way to add, edit, delete or copy', (
    tester,
  ) async {
    final log = <http.Request>[];
    final api = _api([_place('p1', "Grandma's", 38.8, -75.0)], log: log);
    await tester.pumpWidget(_harness(api, isAdmin: false));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('add-place-button')), findsNothing);
    expect(find.byKey(const Key('edit-place-p1')), findsNothing);
    expect(find.byKey(const Key('delete-place-p1')), findsNothing);
    expect(find.byKey(const Key('places-menu-button')), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);

    // Purely a viewer: it only ever reads.
    expect(log.every((r) => r.method == 'GET'), isTrue);
  });

  testWidgets('is read-only for an admin too — they manage from Admin', (
    tester,
  ) async {
    final api = _api([_place('p1', "Grandma's", 38.8, -75.0)]);
    await tester.pumpWidget(_harness(api, isAdmin: true));
    await tester.pumpAndSettle();

    expect(find.text("Grandma's"), findsOneWidget);
    expect(find.byKey(const Key('add-place-button')), findsNothing);
    expect(find.byKey(const Key('edit-place-p1')), findsNothing);
    expect(find.byKey(const Key('delete-place-p1')), findsNothing);
    expect(find.byKey(const Key('places-menu-button')), findsNothing);
  });

  testWidgets('an empty list says the admin has added none yet', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(_api([]), isAdmin: false));
    await tester.pumpAndSettle();

    expect(find.text('No places yet'), findsOneWidget);
    expect(find.textContaining("admin hasn't added"), findsOneWidget);
  });

  testWidgets('a failed load offers a retry that refetches', (tester) async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      if (calls == 1) return http.Response('boom', 500);
      return _json({
        'group_id': 'g1',
        'places': [_place('p1', "Grandma's", 38.8, -75.0)],
      });
    });
    await tester.pumpWidget(
      _harness(
        ApiClient(baseUrl: 'http://test', client: client),
        isAdmin: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text("Grandma's"), findsOneWidget);
  });
}
