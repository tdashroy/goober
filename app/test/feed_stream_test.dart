import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:goober/src/feed_stream.dart';
import 'package:goober/src/models.dart';

/// A ride as JSON, minimal but complete enough to parse — the shape a delta
/// carries.
Map<String, dynamic> _rideJson({
  required String id,
  String status = 'open',
  String groupId = 'g1',
  String createdAt = '2027-07-04T18:00:00Z',
}) => {
  'id': id,
  'group_id': groupId,
  'status': status,
  'passenger': {'id': 'p1', 'display_name': 'Emily'},
  'driver': null,
  'targets': [
    {'id': 't1', 'display_name': 'Wendel'},
  ],
  'responses': <Map<String, dynamic>>[],
  'pickup': {
    'id': 'pl1',
    'group_id': groupId,
    'name': 'The Pier',
    'lat': 38.9,
    'lng': -75.1,
  },
  'dropoff': {
    'id': 'pl2',
    'group_id': groupId,
    'name': "Grandma's",
    'lat': 38.8,
    'lng': -75.0,
  },
  'party_size': 1,
  'party': <Map<String, dynamic>>[],
  'offer': null,
  'scheduled_for': null,
  'created_at': createdAt,
};

Ride _ride({required String id, String createdAt = '2027-07-04T18:00:00Z'}) =>
    Ride.fromJson(_rideJson(id: id, createdAt: createdAt));

Feed _feed(List<Ride> rides) =>
    Feed(groupId: 'g1', groupName: 'Beach 2027', rides: rides);

void main() {
  group('parseServerSentEvents', () {
    test(
      'parses an event name and its data, dispatched on a blank line',
      () async {
        final msgs = await parseServerSentEvents(
          Stream.fromIterable(['event: ride', 'data: {"a":1}', '']),
        ).toList();

        expect(msgs, hasLength(1));
        expect(msgs.single.event, 'ride');
        expect(msgs.single.data, '{"a":1}');
      },
    );

    test(
      'joins multiple data lines with newlines and ignores comments',
      () async {
        final msgs = await parseServerSentEvents(
          Stream.fromIterable([
            ': keep-alive', // a comment / heartbeat — no field
            'event: ride',
            'data: line one',
            'data: line two',
            '',
          ]),
        ).toList();

        expect(msgs.single.event, 'ride');
        expect(msgs.single.data, 'line one\nline two');
      },
    );

    test('dispatches each event when its blank line arrives', () async {
      final msgs = await parseServerSentEvents(
        Stream.fromIterable([
          'event: ride',
          'data: a',
          '',
          'event: resync',
          'data:',
          '',
        ]),
      ).toList();

      expect(msgs.map((m) => m.event), ['ride', 'resync']);
    });

    test('strips only a single leading space after the colon', () async {
      final msgs = await parseServerSentEvents(
        Stream.fromIterable(['data:  two leading spaces', '']),
      ).toList();

      // One space is syntax; the rest is data. With no event field, the name
      // defaults to "message".
      expect(msgs.single.data, ' two leading spaces');
      expect(msgs.single.event, 'message');
    });

    test('an unterminated event at end of stream is not dispatched', () async {
      final msgs = await parseServerSentEvents(
        Stream.fromIterable(['event: ride', 'data: a']),
      ).toList();

      expect(msgs, isEmpty);
    });
  });

  group('LiveFeed', () {
    test(
      'forwards deltas, and does not resync on the first connection',
      () async {
        final conn = StreamController<FeedEvent>();
        final live = LiveFeed(connect: () => conn.stream);
        final seen = <FeedEvent>[];
        final sub = live.events.listen(seen.add);

        conn.add(RideChanged(_ride(id: 'r1')));
        await Future<void>.delayed(Duration.zero);

        expect(seen, hasLength(1));
        expect(seen.single, isA<RideChanged>());
        expect(seen.whereType<FeedResync>(), isEmpty);

        await sub.cancel();
        await live.close();
      },
    );

    test('reconnects after a drop and asks for a resync', () async {
      final conns = [
        StreamController<FeedEvent>(),
        StreamController<FeedEvent>(),
      ];
      var connects = 0;
      final live = LiveFeed(
        connect: () => conns[connects++].stream,
        retryDelay: const Duration(milliseconds: 5),
      );
      final seen = <FeedEvent>[];
      final sub = live.events.listen(seen.add);

      // First connection delivers a delta, then drops.
      conns[0].add(RideChanged(_ride(id: 'r1')));
      await Future<void>.delayed(Duration.zero);
      await conns[0].close();

      // After the retry delay it reconnects and delivers another delta.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      conns[1].add(RideChanged(_ride(id: 'r2')));
      await Future<void>.delayed(Duration.zero);

      expect(connects, 2, reason: 'should have reconnected once');

      // A resync is emitted on the reconnect — after the first delta and before
      // the second — so the screen refetches and converges over the gap.
      final resyncAt = seen.indexWhere((e) => e is FeedResync);
      final r2At = seen.indexWhere(
        (e) => e is RideChanged && e.ride.id == 'r2',
      );
      expect(resyncAt, greaterThanOrEqualTo(0));
      expect(resyncAt, lessThan(r2At));
      expect(seen.whereType<RideChanged>().map((e) => e.ride.id), ['r1', 'r2']);

      await sub.cancel();
      await live.close();
    });

    test('close stops it reconnecting', () async {
      final conns = [
        StreamController<FeedEvent>(),
        StreamController<FeedEvent>(),
      ];
      var connects = 0;
      final live = LiveFeed(
        connect: () => conns[connects++].stream,
        retryDelay: const Duration(milliseconds: 5),
      );
      final sub = live.events.listen((_) {});

      // Connected once in the constructor; closing must prevent any reconnect
      // even after the connection drops.
      await live.close();
      await conns[0].close();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(connects, 1);

      await sub.cancel();
    });
  });

  group('Feed.withRide', () {
    test('inserts a new ride, keeping the board newest-first', () {
      final feed = _feed([
        _ride(id: 'r3', createdAt: '2027-07-04T18:02:00Z'),
        _ride(id: 'r1', createdAt: '2027-07-04T18:00:00Z'),
      ]);

      final merged = feed.withRide(
        _ride(id: 'r2', createdAt: '2027-07-04T18:01:00Z'),
      );

      expect(merged.rides.map((r) => r.id), ['r3', 'r2', 'r1']);
    });

    test('replaces an existing ride in place', () {
      final feed = _feed([_ride(id: 'r1')]);

      final merged = feed.withRide(
        Ride.fromJson(_rideJson(id: 'r1', status: 'accepted')),
      );

      expect(merged.rides, hasLength(1));
      expect(merged.rides.single.status, 'accepted');
    });

    test('ignores a ride belonging to another group', () {
      final feed = _feed([_ride(id: 'r1')]);

      final merged = feed.withRide(
        Ride.fromJson(_rideJson(id: 'r9', groupId: 'other')),
      );

      expect(merged.rides.map((r) => r.id), ['r1']);
    });
  });
}
