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

String _placesJson(List<Map<String, dynamic>> places) =>
    jsonEncode({'group_id': 'g1', 'places': places});

/// An API whose GET returns [initial], and whose mutating verbs return whatever
/// [onMutate] computes (defaults to echoing [initial]). Records each request.
ApiClient _api({
  required List<Map<String, dynamic>> initial,
  List<Map<String, dynamic>> Function(http.Request req)? onMutate,
  List<http.Request>? log,
}) {
  final client = MockClient((req) async {
    log?.add(req);
    if (req.method == 'GET') {
      return http.Response(_placesJson(initial), 200);
    }
    final result = onMutate?.call(req) ?? initial;
    return http.Response(_placesJson(result), 200);
  });
  return ApiClient(baseUrl: 'http://test', client: client);
}

Widget _harness(ApiClient api, Session session) => MaterialApp(
  theme: buildGooberTheme(),
  home: PlacesScreen(api: api, session: session),
);

void main() {
  testWidgets('lists the group places for a member', (tester) async {
    final api = _api(
      initial: [
        _place('p1', "Grandma's", 38.8, -75.0),
        _place('p2', 'The Pier', 38.9, -75.1),
      ],
    );
    await tester.pumpWidget(_harness(api, _session(isAdmin: false)));
    await tester.pumpAndSettle();

    expect(find.text("Grandma's"), findsOneWidget);
    expect(find.text('The Pier'), findsOneWidget);
  });

  testWidgets('non-admins see no add / edit / delete affordances', (
    tester,
  ) async {
    final api = _api(initial: [_place('p1', "Grandma's", 38.8, -75.0)]);
    await tester.pumpWidget(_harness(api, _session(isAdmin: false)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('add-place-button')), findsNothing);
    expect(find.byKey(const Key('edit-place-p1')), findsNothing);
    expect(find.byKey(const Key('delete-place-p1')), findsNothing);
  });

  testWidgets('admins see add and per-place edit / delete controls', (
    tester,
  ) async {
    final api = _api(initial: [_place('p1', "Grandma's", 38.8, -75.0)]);
    await tester.pumpWidget(_harness(api, _session(isAdmin: true)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('add-place-button')), findsOneWidget);
    expect(find.byKey(const Key('edit-place-p1')), findsOneWidget);
    expect(find.byKey(const Key('delete-place-p1')), findsOneWidget);
  });

  testWidgets('empty state differs for admin vs member', (tester) async {
    // Member.
    await tester.pumpWidget(
      _harness(_api(initial: []), _session(isAdmin: false)),
    );
    await tester.pumpAndSettle();
    expect(find.text('No places yet'), findsOneWidget);
    expect(find.textContaining("admin hasn't added"), findsOneWidget);

    // Admin.
    await tester.pumpWidget(
      _harness(_api(initial: []), _session(isAdmin: true)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Add the houses'), findsOneWidget);
  });

  testWidgets('admin adds a place through the dialog', (tester) async {
    final log = <http.Request>[];
    final api = _api(
      initial: [],
      log: log,
      onMutate: (req) => [_place('p9', 'The Pier', 38.9, -75.1)],
    );
    await tester.pumpWidget(_harness(api, _session(isAdmin: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add-place-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('place-name-field')),
      'The Pier',
    );
    await tester.enterText(find.byKey(const Key('place-lat-field')), '38.9');
    await tester.enterText(find.byKey(const Key('place-lng-field')), '-75.1');
    await tester.tap(find.byKey(const Key('save-place-button')));
    await tester.pumpAndSettle();

    // A POST was made and the new place now shows in the list.
    expect(log.any((r) => r.method == 'POST'), isTrue);
    expect(find.text('The Pier'), findsOneWidget);
  });

  testWidgets('the add dialog rejects a bad latitude', (tester) async {
    final log = <http.Request>[];
    final api = _api(initial: [], log: log);
    await tester.pumpWidget(_harness(api, _session(isAdmin: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add-place-button')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('place-name-field')), 'X');
    await tester.enterText(find.byKey(const Key('place-lat-field')), '999');
    await tester.enterText(find.byKey(const Key('place-lng-field')), '0');
    await tester.tap(find.byKey(const Key('save-place-button')));
    await tester.pumpAndSettle();

    // Validation blocked the save: no POST, error shown, dialog still open.
    expect(log.any((r) => r.method == 'POST'), isFalse);
    expect(find.textContaining('Latitude must be'), findsOneWidget);
  });

  testWidgets('copy menu is admin-only', (tester) async {
    final api = _api(initial: [_place('p1', "Grandma's", 38.8, -75.0)]);
    await tester.pumpWidget(_harness(api, _session(isAdmin: false)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('places-menu-button')), findsNothing);
  });

  testWidgets('admin copies places from another group', (tester) async {
    final log = <http.Request>[];
    final api = _api(
      initial: [],
      log: log,
      onMutate: (req) => [_place('p1', "Grandma's", 38.8, -75.0)],
    );
    await tester.pumpWidget(_harness(api, _session(isAdmin: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('places-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('copy-places-menu-item')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('copy-from-group-field')),
      'g0',
    );
    await tester.tap(find.byKey(const Key('confirm-copy-places')));
    await tester.pumpAndSettle();

    final copy = log.firstWhere((r) => r.url.path.endsWith('/places/copy'));
    expect(jsonDecode(copy.body)['from_group_id'], 'g0');
    expect(find.text("Grandma's"), findsOneWidget);
  });

  testWidgets('admin deletes a place after confirming', (tester) async {
    final log = <http.Request>[];
    final api = _api(
      initial: [_place('p1', "Grandma's", 38.8, -75.0)],
      log: log,
      onMutate: (req) => [], // deletion empties the list
    );
    await tester.pumpWidget(_harness(api, _session(isAdmin: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete-place-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-place')));
    await tester.pumpAndSettle();

    expect(log.any((r) => r.method == 'DELETE'), isTrue);
    expect(find.text("Grandma's"), findsNothing);
    expect(find.text('No places yet'), findsOneWidget);
  });
}
