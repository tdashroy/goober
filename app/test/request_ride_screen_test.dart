import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goober/src/api_client.dart';
import 'package:goober/src/models.dart';
import 'package:goober/src/screens/request_ride_screen.dart';
import 'package:goober/src/theme.dart';
import 'package:goober/src/time_format.dart';
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

Map<String, dynamic> _place(String id, String name) => {
  'id': id,
  'group_id': 'g1',
  'name': name,
  'lat': 38.9,
  'lng': -75.1,
};

Map<String, dynamic> _member(String id, String name) => {
  'id': id,
  'display_name': name,
  'is_admin': false,
};

/// The ride the server echoes back on a successful request. The screen only
/// cares that it parses, so the details are stand-ins.
Map<String, dynamic> _createdRide() => {
  'id': 'r1',
  'group_id': 'g1',
  'status': 'open',
  'passenger': {'id': 'm1', 'display_name': 'Troy'},
  'targets': [
    {'id': 'm2', 'display_name': 'Wendel'},
  ],
  'pickup': _place('p1', 'The Pier'),
  'dropoff': _place('p2', "Grandma's"),
  'party_size': 1,
  'party': <dynamic>[],
  'offer': null,
  'scheduled_for': null,
  'created_at': '2027-07-04T18:00:00Z',
};

/// A response shaped like the server's: UTF-8 bytes under a bare
/// `application/json` (no charset), which is what axum sends.
http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json'},
);

/// An API serving the group's places and roster, recording every POST body so a
/// test can assert exactly what was asked for. [rideStatus] lets a test make the
/// request fail; [rideUnreachable] makes it die in transit instead, the way an
/// unreachable server does.
ApiClient _api({
  List<Map<String, dynamic>>? places,
  List<Map<String, dynamic>>? members,
  List<Map<String, dynamic>>? posted,
  int rideStatus = 200,
  String rideError = 'request failed',
  bool rideUnreachable = false,
}) {
  final client = MockClient((req) async {
    if (req.method == 'GET' && req.url.path.endsWith('/places')) {
      return _json({
        'group_id': 'g1',
        'places':
            places ?? [_place('p1', 'The Pier'), _place('p2', "Grandma's")],
      });
    }
    if (req.method == 'GET' && req.url.path.endsWith('/members')) {
      return _json({
        'group_id': 'g1',
        'members':
            members ??
            [
              _member('m1', 'Troy'),
              _member('m2', 'Wendel'),
              _member('m3', 'Emily'),
            ],
      });
    }
    // POST /rides
    if (rideUnreachable) {
      throw http.ClientException('connection refused');
    }
    posted?.add(jsonDecode(req.body) as Map<String, dynamic>);
    if (rideStatus != 200) {
      return _json({'error': rideError}, rideStatus);
    }
    return _json(_createdRide());
  });
  return ApiClient(baseUrl: 'http://test', client: client);
}

/// Pumps the screen and waits for places + roster to load. Returns the list the
/// screen's pop result lands in, so a test can assert the feed is told to
/// refresh.
Future<List<bool?>> _pumpScreen(
  WidgetTester tester,
  ApiClient api, {
  Future<TimeOfDay?> Function(BuildContext, TimeOfDay)? pickScheduledTime,
  Future<DateTime?> Function(BuildContext, DateTime)? pickScheduledDay,
}) async {
  // The form is a ListView, which only builds what fits on screen. Give the test
  // a tall surface so every field is built and tappable without scrolling.
  await tester.binding.setSurfaceSize(const Size(1000, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final popped = <bool?>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildGooberTheme(),
      home: Builder(
        builder: (context) => TextButton(
          child: const Text('open'),
          onPressed: () async {
            final result = await Navigator.of(context).push<bool>(
              MaterialPageRoute<bool>(
                builder: (_) => RequestRideScreen(
                  api: api,
                  session: _session(),
                  pickScheduledTime: pickScheduledTime,
                  pickScheduledDay: pickScheduledDay,
                ),
              ),
            );
            popped.add(result);
          },
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return popped;
}

/// Choose an option in one of the screen's dropdowns. The chosen name also
/// renders on the closed field or its chip, so pick the menu item — the last
/// match on screen.
Future<void> _selectFrom(
  WidgetTester tester,
  String fieldKey,
  String name,
) async {
  await tester.tap(find.byKey(Key(fieldKey)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

/// Add someone to the set of people being asked to drive.
Future<void> _ping(WidgetTester tester, String name) =>
    _selectFrom(tester, 'target-picker', name);

/// Add a co-rider: the "+" opens the same picker the ping list uses.
Future<void> _addRider(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const Key('add-rider-button')));
  await tester.pumpAndSettle();
  await _selectFrom(tester, 'rider-picker', name);
}

/// Who the picker under [fieldKey] is offering, in the order it lists them.
List<String> _optionsIn(WidgetTester tester, String fieldKey) => tester
    .widget<DropdownButton<String>>(
      find.descendant(
        of: find.byKey(Key(fieldKey)),
        matching: find.byType(DropdownButton<String>),
      ),
    )
    .items!
    .map((item) => (item.child as Text).data!)
    .toList();

int _minuteOfDay(TimeOfDay time) => time.hour * 60 + time.minute;

/// A clock time on today's date — what the screen makes of a picked time.
DateTime _atToday(TimeOfDay time) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, time.hour, time.minute);
}

/// Fill in the minimum a request needs: a route and someone to ask.
Future<void> _fillMinimalRequest(WidgetTester tester) async {
  await _selectFrom(tester, 'pickup-field', 'The Pier');
  await _selectFrom(tester, 'dropoff-field', "Grandma's");
  await _ping(tester, 'Wendel');
}

void main() {
  testWidgets('requests a ride, pinging the one person chosen', (tester) async {
    final posted = <Map<String, dynamic>>[];
    final popped = await _pumpScreen(tester, _api(posted: posted));

    await _fillMinimalRequest(tester);
    await tester.enterText(find.byKey(const Key('offer-field')), '🍪 cookies');
    await tester.tap(find.byKey(const Key('party-size-increment')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('party-size-increment')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();

    expect(posted, hasLength(1));
    expect(posted.single['pickup_id'], 'p1');
    expect(posted.single['dropoff_id'], 'p2');
    // Asking one person is a set of one.
    expect(posted.single['target_ids'], ['m2']);
    expect(posted.single['party_size'], 3);
    expect(posted.single['offer'], '🍪 cookies');
    // No time chosen means "now".
    expect(posted.single['scheduled_for'], isNull);

    // The screen pops `true` so the feed behind it refreshes.
    expect(popped, [true]);
  });

  testWidgets('pings several people at once, each a chip you can drop', (
    tester,
  ) async {
    final posted = <Map<String, dynamic>>[];
    await _pumpScreen(
      tester,
      _api(
        posted: posted,
        members: [
          _member('m1', 'Troy'),
          _member('m2', 'Wendel'),
          _member('m3', 'Emily'),
          _member('m4', 'Grandma'),
        ],
      ),
    );

    await _selectFrom(tester, 'pickup-field', 'The Pier');
    await _selectFrom(tester, 'dropoff-field', "Grandma's");

    // The list is sorted by name, and everyone picked drops out of it.
    expect(_optionsIn(tester, 'target-picker'), [
      'Emily',
      'Grandma',
      'Wendel',
    ]);
    await _ping(tester, 'Grandma');
    await _ping(tester, 'Wendel');
    await _ping(tester, 'Emily');
    expect(_optionsIn(tester, 'target-picker'), isEmpty);

    // Each shows as a chip — and Emily, asked by mistake, comes straight back off.
    expect(find.byKey(const Key('target-chip-m2')), findsOneWidget);
    expect(find.byKey(const Key('target-chip-m3')), findsOneWidget);
    expect(find.byKey(const Key('target-chip-m4')), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('target-chip-m3')),
        matching: find.byTooltip('Delete'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('target-chip-m3')), findsNothing);
    expect(_optionsIn(tester, 'target-picker'), ['Emily']);

    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();

    // Everyone still chosen is pinged: whoever can come, comes.
    expect(posted.single['target_ids'], ['m4', 'm2']);
  });

  testWidgets('party size defaults to 1 ("just me")', (tester) async {
    final posted = <Map<String, dynamic>>[];
    await _pumpScreen(tester, _api(posted: posted));

    final value = tester.widget<Text>(
      find.byKey(const Key('party-size-value')),
    );
    expect(value.data, '1');

    // Submitting without touching party size sends 1.
    await _fillMinimalRequest(tester);
    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();

    expect(posted.single['party_size'], 1);
  });

  testWidgets('party size steps between 1 and the cap', (tester) async {
    await _pumpScreen(tester, _api());

    String? value() =>
        tester.widget<Text>(find.byKey(const Key('party-size-value'))).data;
    bool enabled(String key) =>
        tester.widget<IconButton>(find.byKey(Key(key))).onPressed != null;

    // Starts at 1 with nowhere to go but up.
    expect(value(), '1');
    expect(enabled('party-size-decrement'), isFalse);
    expect(enabled('party-size-increment'), isTrue);

    // Counts up by exact steps until the cap, where the plus button gives out.
    for (var i = 1; i < maxPartySize; i++) {
      await tester.tap(find.byKey(const Key('party-size-increment')));
      await tester.pump();
      expect(value(), '${i + 1}');
    }
    expect(enabled('party-size-increment'), isFalse);
    expect(enabled('party-size-decrement'), isTrue);

    // And back down again.
    await tester.tap(find.byKey(const Key('party-size-decrement')));
    await tester.pump();
    expect(value(), '${maxPartySize - 1}');
    expect(enabled('party-size-increment'), isTrue);
  });

  testWidgets('scheduling asks for the time, on today', (tester) async {
    final timeAsks = <TimeOfDay>[];
    final dayAsks = <DateTime>[];

    await _pumpScreen(
      tester,
      _api(),
      // The passenger takes the time they're offered.
      pickScheduledTime: (_, initial) async {
        timeAsks.add(initial);
        return initial;
      },
      pickScheduledDay: (_, initial) async {
        dayAsks.add(initial);
        return null;
      },
    );

    await _fillMinimalRequest(tester);
    expect(find.byKey(const Key('pick-time-button')), findsNothing);

    await tester.tap(find.byKey(const Key('timing-scheduled')));
    await tester.pumpAndSettle();

    // Choosing "Later" pops the time picker and nothing else: the day is today
    // already, and only says so.
    expect(timeAsks, hasLength(1));
    expect(dayAsks, isEmpty);
    expect(find.byKey(const Key('pick-day-button')), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);

    // It opens an hour out (give or take the minute this test takes to run), and
    // shows back what was picked.
    final asked = timeAsks.single;
    final anHourOut = TimeOfDay.fromDateTime(
      DateTime.now().add(const Duration(hours: 1)),
    );
    expect(
      _minuteOfDay(anHourOut) - _minuteOfDay(asked),
      inInclusiveRange(0, 1),
    );
    expect(find.text(formatClockTime(_atToday(asked))), findsOneWidget);
  });

  testWidgets('the day can be changed after the time is picked', (tester) async {
    final posted = <Map<String, dynamic>>[];
    final tomorrow = DateTime.now().add(const Duration(days: 1));

    await _pumpScreen(
      tester,
      _api(posted: posted),
      pickScheduledTime: (_, _) async => const TimeOfDay(hour: 9, minute: 0),
      pickScheduledDay: (_, _) async => tomorrow,
    );

    await _fillMinimalRequest(tester);
    await tester.tap(find.byKey(const Key('timing-scheduled')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('pick-day-button')));
    await tester.pumpAndSettle();
    expect(find.text('Tomorrow'), findsOneWidget);

    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();

    // The day the passenger moved to, at the time they picked, as a UTC instant
    // — the server speaks UTC.
    final wanted = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9);
    expect(posted.single['scheduled_for'], wanted.toUtc().toIso8601String());
  });

  testWidgets('backing out of the time picker leaves the day to choose', (
    tester,
  ) async {
    final posted = <Map<String, dynamic>>[];
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    // Backed out of first, then answered when asked again.
    final times = <TimeOfDay?>[null, const TimeOfDay(hour: 9, minute: 0)];

    await _pumpScreen(
      tester,
      _api(posted: posted),
      pickScheduledTime: (_, _) async => times.removeAt(0),
      pickScheduledDay: (_, _) async => tomorrow,
    );

    await _fillMinimalRequest(tester);
    await tester.tap(find.byKey(const Key('timing-scheduled')));
    await tester.pumpAndSettle();

    // Still scheduling, with no time yet — so the day can be chosen first.
    expect(find.text('Pick a time'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pick-day-button')));
    await tester.pumpAndSettle();
    expect(find.text('Tomorrow'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pick-time-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();

    final wanted = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9);
    expect(posted.single['scheduled_for'], wanted.toUtc().toIso8601String());
  });

  testWidgets('a time already gone by today is refused', (tester) async {
    final posted = <Map<String, dynamic>>[];

    await _pumpScreen(
      tester,
      _api(posted: posted),
      // Midnight today is behind whenever this runs.
      pickScheduledTime: (_, _) async => const TimeOfDay(hour: 0, minute: 0),
    );

    await _fillMinimalRequest(tester);
    await tester.tap(find.byKey(const Key('timing-scheduled')));
    await tester.pumpAndSettle();

    // Said as soon as it's picked, not held back until the request is sent.
    expect(find.byKey(const Key('request-ride-error')), findsOneWidget);

    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('request-ride-error')), findsOneWidget);
    expect(posted, isEmpty);
  });

  testWidgets('scheduling without picking a time is refused', (tester) async {
    final posted = <Map<String, dynamic>>[];
    await _pumpScreen(
      tester,
      _api(posted: posted),
      pickScheduledTime: (_, _) async => null,
    );

    await _fillMinimalRequest(tester);
    await tester.tap(find.byKey(const Key('timing-scheduled')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();

    expect(find.text('Pick a time, or switch to Now.'), findsOneWidget);
    expect(posted, isEmpty);
  });

  testWidgets('a request needs a route and someone to ask', (tester) async {
    final posted = <Map<String, dynamic>>[];
    await _pumpScreen(tester, _api(posted: posted));

    // Nothing filled in.
    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('request-ride-error')), findsOneWidget);

    // A route that goes nowhere.
    await _selectFrom(tester, 'pickup-field', 'The Pier');
    await _selectFrom(tester, 'dropoff-field', 'The Pier');
    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();
    expect(find.text('Pick two different places.'), findsOneWidget);

    // A real route, but nobody pinged.
    await _selectFrom(tester, 'dropoff-field', "Grandma's");
    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();
    expect(find.text('Choose someone to ask.'), findsOneWidget);

    expect(posted, isEmpty);
  });

  testWidgets('you cannot ping yourself for a ride', (tester) async {
    await _pumpScreen(tester, _api());

    // The picker offers everyone but you.
    expect(_optionsIn(tester, 'target-picker'), ['Emily', 'Wendel']);
  });

  testWidgets('the passenger can add who is riding along', (tester) async {
    final posted = <Map<String, dynamic>>[];
    await _pumpScreen(tester, _api(posted: posted));

    await _fillMinimalRequest(tester);
    await tester.tap(find.byKey(const Key('party-size-increment')));
    await tester.pumpAndSettle();

    await _addRider(tester, 'Emily');
    expect(find.byKey(const Key('rider-chip-m3')), findsOneWidget);

    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();

    expect(posted.single['party_member_ids'], ['m3']);
  });

  testWidgets('you cannot add a party bigger than the party size', (
    tester,
  ) async {
    final posted = <Map<String, dynamic>>[];
    await _pumpScreen(
      tester,
      _api(
        posted: posted,
        members: [
          _member('m1', 'Troy'),
          _member('m2', 'Wendel'),
          _member('m3', 'Emily'),
          _member('m4', 'Grandma'),
        ],
      ),
    );

    bool canAddRider() =>
        tester
            .widget<IconButton>(find.byKey(const Key('add-rider-button')))
            .onPressed !=
        null;

    await _fillMinimalRequest(tester);

    // A party of one is just you: there's nobody to add.
    expect(canAddRider(), isFalse);

    // A party of two has room for exactly one other rider — once they're in,
    // the "+" gives out.
    await tester.tap(find.byKey(const Key('party-size-increment')));
    await tester.pumpAndSettle();
    expect(canAddRider(), isTrue);
    await _addRider(tester, 'Emily');
    expect(canAddRider(), isFalse);

    // Make room and one more can come along.
    await tester.tap(find.byKey(const Key('party-size-increment')));
    await tester.pumpAndSettle();
    await _addRider(tester, 'Grandma');

    // Shrinking the party back down drops the rider it no longer has room for,
    // rather than sending a party that contradicts the count.
    await tester.tap(find.byKey(const Key('party-size-decrement')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rider-chip-m4')), findsNothing);

    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();

    expect(posted.single['party_size'], 2);
    expect(posted.single['party_member_ids'], ['m3']);
  });

  testWidgets('you cannot add anyone you are asking to drive as a rider', (
    tester,
  ) async {
    final posted = <Map<String, dynamic>>[];
    await _pumpScreen(
      tester,
      _api(
        posted: posted,
        members: [
          _member('m1', 'Troy'),
          _member('m2', 'Wendel'),
          _member('m3', 'Emily'),
          _member('m4', 'Grandma'),
        ],
      ),
    );

    await _selectFrom(tester, 'pickup-field', 'The Pier');
    await _selectFrom(tester, 'dropoff-field', "Grandma's");
    await tester.tap(find.byKey(const Key('party-size-increment')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('party-size-increment')));
    await tester.pumpAndSettle();

    // Wendel and Grandma are being asked to drive, so neither is on offer as a
    // co-rider.
    await _ping(tester, 'Wendel');
    await _ping(tester, 'Grandma');
    await tester.tap(find.byKey(const Key('add-rider-button')));
    await tester.pumpAndSettle();
    expect(_optionsIn(tester, 'rider-picker'), ['Emily']);

    // Add Emily, then ask *her* to drive too: she can't be both, so she drops
    // out of the party.
    await _selectFrom(tester, 'rider-picker', 'Emily');
    expect(find.byKey(const Key('rider-chip-m3')), findsOneWidget);
    await _ping(tester, 'Emily');
    expect(find.byKey(const Key('rider-chip-m3')), findsNothing);

    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();

    expect(posted.single['target_ids'], ['m2', 'm4', 'm3']);
    expect(posted.single['party_member_ids'], isEmpty);
  });

  testWidgets('a rejected request keeps the form and shows why', (
    tester,
  ) async {
    final popped = await _pumpScreen(
      tester,
      _api(rideStatus: 400, rideError: 'pickup and dropoff must be different'),
    );

    await _fillMinimalRequest(tester);
    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();

    expect(find.text('pickup and dropoff must be different'), findsOneWidget);
    // Still on the form — nothing was popped, so the feed doesn't refresh.
    expect(find.byKey(const Key('submit-ride-button')), findsOneWidget);
    expect(popped, isEmpty);
  });

  testWidgets('an unreachable server re-enables the form and says so', (
    tester,
  ) async {
    final popped = await _pumpScreen(tester, _api(rideUnreachable: true));

    await _fillMinimalRequest(tester);
    await tester.tap(find.byKey(const Key('submit-ride-button')));
    await tester.pumpAndSettle();

    // The failure is reported...
    expect(find.byKey(const Key('request-ride-error')), findsOneWidget);
    // ...and the button is live again for a retry, not stuck on "Asking…".
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('submit-ride-button')),
    );
    expect(button.onPressed, isNotNull);
    expect(find.text('Ask for a ride'), findsOneWidget);
    expect(popped, isEmpty);
  });

  testWidgets('says so plainly when the group has too few places', (
    tester,
  ) async {
    await _pumpScreen(tester, _api(places: [_place('p1', 'The Pier')]));

    expect(find.text('No places to ride between'), findsOneWidget);
    expect(find.byKey(const Key('submit-ride-button')), findsNothing);
  });

  testWidgets('says so plainly when there is nobody to ask', (tester) async {
    await _pumpScreen(tester, _api(members: [_member('m1', 'Troy')]));

    expect(find.text("You're the only one here"), findsOneWidget);
    expect(find.byKey(const Key('submit-ride-button')), findsNothing);
  });
}
