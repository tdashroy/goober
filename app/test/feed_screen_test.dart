import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goober/src/api_client.dart';
import 'package:goober/src/models.dart';
import 'package:goober/src/screens/feed_screen.dart';
import 'package:goober/src/screens/manage_places_screen.dart';
import 'package:goober/src/screens/places_screen.dart';
import 'package:goober/src/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Session _session({bool isAdmin = true}) => Session(
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

Map<String, dynamic> _place(String id, String name) => {
  'id': id,
  'group_id': 'g1',
  'name': name,
  'lat': 38.9,
  'lng': -75.1,
};

Map<String, dynamic> _ref(String id, String name) => {
  'id': id,
  'display_name': name,
};

/// The person looking at the board — the session's own member.
Map<String, dynamic> _viewer() => _ref('m1', 'Troy');

/// What one pinged member said back, as the feed sends it.
Map<String, dynamic> _response(String who, String said, {String? named}) => {
  'member': _ref('t-$who', who),
  'response': said,
  'person': named == null ? null : _ref('t-$named', named),
};

/// A ride as the feed receives it from the server.
///
/// [asksViewer] pings the person looking at the board (so they get the response
/// menu) and [fromViewer] makes the ride theirs (so a lead is theirs to act on).
Map<String, dynamic> _ride({
  String id = 'r1',
  String passenger = 'Emily',
  List<String> targets = const ['Wendel'],
  String pickup = 'The Pier',
  String dropoff = "Grandma's",
  int partySize = 1,
  String? offer,
  String? scheduledFor,
  List<String> party = const [],
  String status = 'open',
  bool fromViewer = false,
  bool asksViewer = false,
  Map<String, dynamic>? driver,
  List<Map<String, dynamic>> responses = const [],
}) => {
  'id': id,
  'group_id': 'g1',
  'status': status,
  'passenger': fromViewer ? _viewer() : _ref('p-$passenger', passenger),
  'driver': driver,
  'responses': responses,
  'targets': [
    for (final name in targets) _ref('t-$name', name),
    if (asksViewer) _viewer(),
  ],
  'pickup': _place('p1', pickup),
  'dropoff': _place('p2', dropoff),
  'party_size': partySize,
  'party': [
    for (final name in party) {'id': 'm-$name', 'display_name': name},
  ],
  'offer': offer,
  'scheduled_for': scheduledFor,
  'created_at': '2027-07-04T18:00:00Z',
};

/// A response shaped like the server's: UTF-8 bytes under a bare
/// `application/json` (no charset), which is what axum sends.
http.Response _json(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: {'content-type': 'application/json'},
);

/// Serves the feed, plus the group's places for the screens reachable from it.
ApiClient _feedApi(
  List<Map<String, dynamic>> rides, {
  List<Map<String, dynamic>> places = const [],
}) {
  final client = MockClient((req) async {
    if (req.url.path.endsWith('/places')) {
      return _json({'group_id': 'g1', 'places': places});
    }
    return _json({
      'group_id': 'g1',
      'group_name': 'Beach 2027',
      'rides': rides,
    });
  });
  return ApiClient(baseUrl: 'http://test', client: client);
}

/// Serves the feed plus the places + roster the request screen loads, so a test
/// can tap through from the feed and land on a live form.
ApiClient _feedAndRequestApi(List<Map<String, dynamic>> rides) {
  final client = MockClient((req) async {
    if (req.url.path.endsWith('/places')) {
      return _json({
        'group_id': 'g1',
        'places': [_place('p1', 'The Pier'), _place('p2', "Grandma's")],
      });
    }
    if (req.url.path.endsWith('/members')) {
      return _json({
        'group_id': 'g1',
        'members': [
          {'id': 'm2', 'display_name': 'Wendel', 'is_admin': false},
        ],
      });
    }
    return _json({
      'group_id': 'g1',
      'group_name': 'Beach 2027',
      'rides': rides,
    });
  });
  return ApiClient(baseUrl: 'http://test', client: client);
}

/// A board that answers the feed, the roster and the steps the card posts back
/// — and remembers what was posted, since that's the thing under test: the card
/// asks the server to move the ride, it never moves it itself.
class _Board {
  _Board(this.rides, {this.afterPost, this.postStatus = 200, this.error});

  /// What the board shows. Swapped for [afterPost] once a step is posted, which
  /// is how the server's answer lands back on the board.
  List<Map<String, dynamic>> rides;
  final List<Map<String, dynamic>>? afterPost;

  /// A step the server refuses — "someone else already took this ride".
  final int postStatus;
  final String? error;

  /// Every step the card posted, as (path, body).
  final List<(String, Map<String, dynamic>)> posts = [];

  late final ApiClient api = ApiClient(
    baseUrl: 'http://test',
    client: MockClient(_handle),
  );

  Future<http.Response> _handle(http.Request req) async {
    if (req.method == 'POST') {
      posts.add((req.url.path, jsonDecode(req.body) as Map<String, dynamic>));
      if (error != null) {
        return http.Response.bytes(
          utf8.encode(jsonEncode({'error': error})),
          postStatus,
          headers: {'content-type': 'application/json'},
        );
      }
      if (afterPost != null) rides = afterPost!;
      // The card ignores the ride it gets back and refetches the board, but the
      // client still parses it, so it has to be a real one.
      return _json(rides.first);
    }
    if (req.url.path.endsWith('/members')) {
      return _json({
        'group_id': 'g1',
        'members': [
          {'id': 't-Wendel', 'display_name': 'Wendel', 'is_admin': false},
          {'id': 't-Susan', 'display_name': 'Susan', 'is_admin': false},
        ],
      });
    }
    return _json({
      'group_id': 'g1',
      'group_name': 'Beach 2027',
      'rides': rides,
    });
  }
}

Future<void> _pumpFeed(
  WidgetTester tester,
  ApiClient api, {
  bool isAdmin = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildGooberTheme(),
      home: FeedScreen(
        api: api,
        session: _session(isAdmin: isAdmin),
        onUnauthenticated: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the empty feed state and the Get a ride button', (
    tester,
  ) async {
    await _pumpFeed(tester, _feedApi([]));

    // Friendly empty state.
    expect(find.byType(EmptyFeed), findsOneWidget);
    expect(find.text('All quiet on the boardwalk'), findsOneWidget);

    // The big "Get a ride" button is present.
    expect(find.byKey(const Key('get-a-ride-button')), findsOneWidget);
    expect(find.text('Get a ride'), findsOneWidget);

    // Group name in the app bar.
    expect(find.text('Beach 2027'), findsOneWidget);
  });

  testWidgets('shows an open request with its route, party size and offer', (
    tester,
  ) async {
    await _pumpFeed(
      tester,
      _feedApi([_ride(partySize: 3, offer: '🍪 cookies')]),
    );

    expect(find.byType(EmptyFeed), findsNothing);
    expect(find.byKey(const Key('ride-r1')), findsOneWidget);

    // Who asked, and who they pinged.
    expect(find.text('Emily → Wendel'), findsOneWidget);
    // The route.
    expect(find.text("The Pier → Grandma's"), findsOneWidget);
    // Party size and offer.
    expect(find.text('3 riding'), findsOneWidget);
    expect(find.text('🍪 cookies'), findsOneWidget);
    // A "now" ride says so.
    expect(find.text('Now'), findsOneWidget);
  });

  testWidgets('a ride pinged to several people names them all', (tester) async {
    await _pumpFeed(
      tester,
      _feedApi([
        _ride(targets: const ['Grandma', 'Jen']),
      ]),
    );

    expect(find.text('Emily → Grandma, Jen'), findsOneWidget);
  });

  testWidgets('a party of one reads as "Just me", and no offer shows none', (
    tester,
  ) async {
    await _pumpFeed(tester, _feedApi([_ride()]));

    expect(find.text('Just me'), findsOneWidget);
    expect(find.byIcon(Icons.card_giftcard), findsNothing);
  });

  testWidgets('a long offer wraps inside the card instead of overflowing', (
    tester,
  ) async {
    const offer =
        "I'll make breakfast tomorrow and do your dishes for the rest of "
        'the week, plus first pick of the boogie boards';
    await _pumpFeed(tester, _feedApi([_ride(offer: offer)]));

    expect(find.text(offer), findsOneWidget);
    // A render overflow would surface here as a FlutterError.
    expect(tester.takeException(), isNull);
  });

  testWidgets('a scheduled ride shows the time it is wanted for', (
    tester,
  ) async {
    await _pumpFeed(
      tester,
      _feedApi([_ride(scheduledFor: '2027-07-04T18:30:00Z')]),
    );

    // Shown in the rider's local time, so compute the expectation the same way
    // rather than hard-coding a time zone.
    final local = DateTime.parse('2027-07-04T18:30:00Z').toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final meridiem = local.hour < 12 ? 'AM' : 'PM';

    expect(find.textContaining('$hour:$minute $meridiem'), findsOneWidget);
    expect(find.text('Now'), findsNothing);
  });

  testWidgets("shows the whole group's rides, newest first", (tester) async {
    await _pumpFeed(
      tester,
      _feedApi([
        _ride(id: 'r2', passenger: 'Wendel', targets: const ['Troy']),
        _ride(id: 'r1', passenger: 'Emily', targets: const ['Wendel']),
      ]),
    );

    // Every ride is on the shared board, not just the viewer's own.
    expect(find.byKey(const Key('ride-r1')), findsOneWidget);
    expect(find.byKey(const Key('ride-r2')), findsOneWidget);

    // In the order the server sent them: newest first.
    final cards = tester.widgetList<RideCard>(find.byType(RideCard)).toList();
    expect(cards.map((c) => c.ride.id), ['r2', 'r1']);
  });

  testWidgets('shows who the passenger tagged as riding along', (tester) async {
    await _pumpFeed(
      tester,
      _feedApi([
        _ride(partySize: 2, party: ['Emily']),
      ]),
    );

    expect(find.text('With Emily'), findsOneWidget);
  });

  testWidgets('Get a ride opens the request flow', (tester) async {
    // The request form is a ListView; a tall surface builds all of it, so the
    // submit button below the fold is there to be found.
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpFeed(tester, _feedAndRequestApi([]));

    await tester.tap(find.byKey(const Key('get-a-ride-button')));
    await tester.pumpAndSettle();

    // Landed on the request screen, with the form ready.
    expect(find.byKey(const Key('submit-ride-button')), findsOneWidget);
    expect(find.text('Where to?'), findsOneWidget);
  });

  testWidgets('the empty board can be pulled to refresh', (tester) async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return _json({
        'group_id': 'g1',
        'group_name': 'Beach 2027',
        'rides': calls == 1 ? [] : [_ride()],
      });
    });
    await _pumpFeed(tester, ApiClient(baseUrl: 'http://test', client: client));

    expect(find.byType(EmptyFeed), findsOneWidget);

    await tester.fling(
      find.text('All quiet on the boardwalk'),
      const Offset(0, 300),
      1000,
    );
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.byType(EmptyFeed), findsNothing);
    expect(find.byKey(const Key('ride-r1')), findsOneWidget);
  });

  testWidgets('the board refetches on the auto-refresh interval, in place', (
    tester,
  ) async {
    var calls = 0;
    final gate = Completer<void>();
    final client = MockClient((req) async {
      calls++;
      if (calls > 1) await gate.future;
      return _json({
        'group_id': 'g1',
        'group_name': 'Beach 2027',
        'rides': calls == 1 ? [] : [_ride()],
      });
    });
    await _pumpFeed(tester, ApiClient(baseUrl: 'http://test', client: client));

    expect(calls, 1);
    expect(find.byType(EmptyFeed), findsOneWidget);

    // The interval elapses and a poll goes out — while it is in flight the
    // board stays as it was, with no spinner thrown over it.
    await tester.pump(FeedScreen.autoRefreshInterval);
    expect(calls, 2);
    expect(find.byType(EmptyFeed), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // The poll lands and the new ride appears.
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(EmptyFeed), findsNothing);
    expect(find.byKey(const Key('ride-r1')), findsOneWidget);
  });

  testWidgets('a failed poll leaves the rendered board alone', (tester) async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      if (calls > 1) throw http.ClientException('connection refused');
      return _json({
        'group_id': 'g1',
        'group_name': 'Beach 2027',
        'rides': [_ride()],
      });
    });
    await _pumpFeed(tester, ApiClient(baseUrl: 'http://test', client: client));

    expect(find.byKey(const Key('ride-r1')), findsOneWidget);

    await tester.pump(FeedScreen.autoRefreshInterval);
    await tester.pump();

    // The poll failed, but the good board is still up — no error screen.
    expect(calls, 2);
    expect(find.byKey(const Key('ride-r1')), findsOneWidget);
    expect(find.text("Couldn't reach Goober"), findsNothing);
  });

  testWidgets('auto-refresh stops when the screen is disposed', (tester) async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return _json({
        'group_id': 'g1',
        'group_name': 'Beach 2027',
        'rides': [_ride()],
      });
    });
    await _pumpFeed(tester, ApiClient(baseUrl: 'http://test', client: client));
    expect(calls, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(FeedScreen.autoRefreshInterval * 2);

    expect(calls, 1);
  });

  // --- the ride lifecycle, from the card ---

  testWidgets('a pinged member gets the four-option menu', (tester) async {
    await _pumpFeed(tester, _feedApi([_ride(asksViewer: true)]));

    expect(find.byKey(const Key('ride-on-my-way-r1')), findsOneWidget);
    expect(find.byKey(const Key('ride-cant-r1')), findsOneWidget);
    expect(find.byKey(const Key('ride-no-cart-r1')), findsOneWidget);
    expect(find.byKey(const Key('ride-someone-else-r1')), findsOneWidget);
  });

  testWidgets('a ride that asked somebody else is one you only watch', (
    tester,
  ) async {
    await _pumpFeed(tester, _feedApi([_ride()]));

    expect(find.byKey(const Key('ride-r1')), findsOneWidget);
    expect(find.byKey(const Key('ride-on-my-way-r1')), findsNothing);
    expect(find.byKey(const Key('ride-cant-r1')), findsNothing);
    expect(find.byKey(const Key('ride-no-cart-r1')), findsNothing);
    expect(find.byKey(const Key('ride-someone-else-r1')), findsNothing);
  });

  testWidgets('"On my way" claims the ride and the board says who is driving', (
    tester,
  ) async {
    final board = _Board(
      [_ride(asksViewer: true)],
      afterPost: [
        _ride(
          asksViewer: true,
          status: 'accepted',
          driver: _viewer(),
          responses: [
            {'member': _viewer(), 'response': 'on_my_way', 'person': null},
          ],
        ),
      ],
    );
    await _pumpFeed(tester, board.api);

    await tester.tap(find.byKey(const Key('ride-on-my-way-r1')));
    await tester.pumpAndSettle();

    expect(board.posts.single.$1, '/groups/g1/rides/r1/actions');
    expect(board.posts.single.$2['action'], 'on_my_way');

    // The board comes back claimed: the menu is gone, and the ride says so.
    expect(find.byKey(const Key('ride-on-my-way-r1')), findsNothing);
    expect(find.text('Troy is on the way'), findsOneWidget);
    // And the driver has the one thing left to do.
    expect(find.byKey(const Key('ride-arrived-r1')), findsOneWidget);
  });

  testWidgets('a ride somebody else claimed first comes back as taken', (
    tester,
  ) async {
    final board = _Board(
      [_ride(asksViewer: true)],
      postStatus: 409,
      error: 'someone else already took this ride',
    );
    await _pumpFeed(tester, board.api);

    await tester.tap(find.byKey(const Key('ride-on-my-way-r1')));
    await tester.pumpAndSettle();

    expect(find.text('someone else already took this ride'), findsOneWidget);
  });

  testWidgets('the driver marks the arrival, then closes the ride out', (
    tester,
  ) async {
    final board = _Board(
      [_ride(asksViewer: true, status: 'accepted', driver: _viewer())],
      afterPost: [
        _ride(asksViewer: true, status: 'arrived', driver: _viewer()),
      ],
    );
    await _pumpFeed(tester, board.api);

    expect(find.text('Troy is on the way'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ride-arrived-r1')));
    await tester.pumpAndSettle();

    expect(board.posts.single.$2['action'], 'arrived');
    expect(find.text('Troy is here'), findsOneWidget);
    expect(find.byKey(const Key('ride-delivered-r1')), findsOneWidget);
  });

  testWidgets('the passenger can close the ride out too', (tester) async {
    final board = _Board(
      [
        _ride(
          fromViewer: true,
          status: 'arrived',
          driver: _ref('t-Wendel', 'Wendel'),
        ),
      ],
      afterPost: [
        _ride(
          fromViewer: true,
          status: 'delivered',
          driver: _ref('t-Wendel', 'Wendel'),
        ),
      ],
    );
    await _pumpFeed(tester, board.api);

    // Waiting at the kerb, the passenger sees the cart arrive.
    expect(find.text('Wendel is here'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ride-delivered-r1')));
    await tester.pumpAndSettle();

    expect(board.posts.single.$2['action'], 'delivered');
    expect(find.text('Delivered by Wendel 🎉'), findsOneWidget);
    expect(find.byKey(const Key('ride-delivered-r1')), findsNothing);
  });

  testWidgets('a "no" says what it knows, and names who took the cart', (
    tester,
  ) async {
    final board = _Board(
      [_ride(asksViewer: true)],
      afterPost: [
        _ride(
          asksViewer: true,
          responses: [_response('Troy', 'no_cart', named: 'Susan')],
        ),
      ],
    );
    await _pumpFeed(tester, board.api);

    await tester.tap(find.byKey(const Key('ride-no-cart-r1')));
    await tester.pumpAndSettle();

    // Naming who has it is picking a person, not typing a sentence.
    expect(find.byKey(const Key('person-picker')), findsOneWidget);
    await tester.tap(find.byKey(const Key('pick-person-t-Susan')));
    await tester.pumpAndSettle();

    expect(board.posts.single.$2['action'], 'no_cart');
    expect(board.posts.single.$2['person_id'], 't-Susan');
    // The ride stays open — whoever else was asked may still come.
    expect(
      find.text("Troy doesn't have a cart — Susan took it"),
      findsOneWidget,
    );
  });

  testWidgets(
    "a lead the passenger can't use is still a sentence they can read",
    (tester) async {
      // Emily's ride, Emily's lead: a bystander reads it and does nothing with it.
      await _pumpFeed(
        tester,
        _feedApi([
          _ride(responses: [_response('Wendel', 'no_cart', named: 'Susan')]),
        ]),
      );

      expect(
        find.text("Wendel doesn't have a cart — Susan took it"),
        findsOneWidget,
      );
      expect(find.byKey(const Key('ask-r1-t-Susan')), findsNothing);
    },
  );

  testWidgets('tapping the person a lead names asks them for the same ride', (
    tester,
  ) async {
    final board = _Board([
      _ride(
        fromViewer: true,
        partySize: 2,
        offer: '🍪 cookies',
        party: ['Emily'],
        responses: [_response('Wendel', 'someone_else', named: 'Susan')],
      ),
    ]);
    await _pumpFeed(tester, board.api);

    expect(find.text('Wendel says Susan will come'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ask-r1-t-Susan')));
    await tester.pumpAndSettle();

    // One tap, and Susan is being asked for exactly the ride that was wanted.
    final (path, body) = board.posts.single;
    expect(path, '/groups/g1/rides');
    expect(body['target_ids'], ['t-Susan']);
    expect(body['pickup_id'], 'p1');
    expect(body['dropoff_id'], 'p2');
    expect(body['party_size'], 2);
    expect(body['offer'], '🍪 cookies');
    expect(body['party_member_ids'], ['m-Emily']);
    expect(find.text('Asked Susan for a ride.'), findsOneWidget);
  });

  testWidgets('admins get a labeled Admin entry point', (tester) async {
    await _pumpFeed(tester, _feedApi([]), isAdmin: true);

    // Labeled in words, not a bare icon.
    expect(find.byKey(const Key('open-admin-button')), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget);
  });

  testWidgets('members see no admin entry point', (tester) async {
    await _pumpFeed(tester, _feedApi([]), isAdmin: false);

    expect(find.byKey(const Key('open-admin-button')), findsNothing);
    expect(find.text('Admin'), findsNothing);
  });

  testWidgets('every member gets a labeled Places entry', (tester) async {
    for (final isAdmin in [true, false]) {
      await _pumpFeed(tester, _feedApi([]), isAdmin: isAdmin);

      expect(find.byKey(const Key('open-places-button')), findsOneWidget);
      expect(find.text('Places'), findsOneWidget);
    }
  });

  testWidgets('a member browses the places, read-only, from the feed', (
    tester,
  ) async {
    await _pumpFeed(
      tester,
      _feedApi([], places: [_place('p1', 'The Pier')]),
      isAdmin: false,
    );

    await tester.tap(find.byKey(const Key('open-places-button')));
    await tester.pumpAndSettle();

    // Landed on the places list: the group's places are there for reference...
    expect(find.byType(PlacesScreen), findsOneWidget);
    expect(find.text('The Pier'), findsOneWidget);

    // ...and nothing on it manages them.
    expect(find.byKey(const Key('add-place-button')), findsNothing);
    expect(find.byKey(const Key('places-menu-button')), findsNothing);
    expect(find.byKey(const Key('edit-place-p1')), findsNothing);
    expect(find.byKey(const Key('delete-place-p1')), findsNothing);
  });

  testWidgets("an admin's Places entry opens the same read-only list", (
    tester,
  ) async {
    await _pumpFeed(
      tester,
      _feedApi([], places: [_place('p1', 'The Pier')]),
      isAdmin: true,
    );

    await tester.tap(find.byKey(const Key('open-places-button')));
    await tester.pumpAndSettle();

    // Admins browse like everyone else; they manage from the Admin door.
    expect(find.text('The Pier'), findsOneWidget);
    expect(find.byKey(const Key('add-place-button')), findsNothing);
    expect(find.byKey(const Key('edit-place-p1')), findsNothing);
  });

  testWidgets('the Admin entry leads on to places management', (tester) async {
    await _pumpFeed(
      tester,
      _feedApi([], places: [_place('p1', 'The Pier')]),
      isAdmin: true,
    );

    await tester.tap(find.byKey(const Key('open-admin-button')));
    await tester.pumpAndSettle();

    // Landed on the admin screen, which offers the admin actions by name.
    expect(find.text('Manage places'), findsOneWidget);

    await tester.tap(find.byKey(const Key('manage-places-action')));
    await tester.pumpAndSettle();

    // ...and on to places management, with the editing controls.
    expect(find.byType(ManagePlacesScreen), findsOneWidget);
    expect(find.byKey(const Key('add-place-button')), findsOneWidget);
    expect(find.byKey(const Key('edit-place-p1')), findsOneWidget);
  });
}
