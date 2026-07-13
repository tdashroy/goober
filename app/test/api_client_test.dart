import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goober/src/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A response shaped like the server's: UTF-8 bytes under a bare
/// `application/json` (no charset), which is what axum sends. `http` falls back
/// to latin1 for a charset-less response, so this is what proves the client
/// reads UTF-8 and doesn't mangle a "🍪 cookies" offer.
http.Response _json(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('ApiClient', () {
    test('createGroup posts the fields and parses the session', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'token': 'tok-123',
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
          headers: {'content-type': 'application/json'},
        );
      });
      final api = ApiClient(baseUrl: 'http://test', client: client);

      final session = await api.createGroup(
        groupName: 'Beach 2027',
        name: 'Troy',
        phone: '555-111-2222',
      );

      expect(captured.url.toString(), 'http://test/groups');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['group_name'], 'Beach 2027');
      expect(body['name'], 'Troy');
      expect(body['phone'], '555-111-2222');

      expect(session.token, 'tok-123');
      expect(session.groupId, 'g1');
      expect(session.member.isAdmin, true);
    });

    test('reads a UTF-8 response body without mangling it', () async {
      // The server sends UTF-8 JSON under a bare `application/json`. Read
      // naively, `http` would decode that as latin1 and turn every non-ASCII
      // character into mojibake — and Goober is full of them.
      final client = MockClient((req) async {
        return _json({
          'token': 'tok-123',
          'group_id': 'g1',
          'group_name': 'Beach 🏖 2027',
          'member': {
            'id': 'm1',
            'group_id': 'g1',
            'display_name': 'Renée',
            'phone': '5551112222',
            'is_admin': true,
          },
        });
      });
      final api = ApiClient(baseUrl: 'http://test', client: client);

      final session = await api.createGroup(
        groupName: 'Beach 🏖 2027',
        name: 'Renée',
        phone: '5551112222',
      );

      expect(session.groupName, 'Beach 🏖 2027');
      expect(session.member.displayName, 'Renée');
    });

    test('fetchFeed sends the bearer token', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({'group_id': 'g1', 'group_name': 'Beach', 'rides': []}),
          200,
        );
      });
      final api = ApiClient(baseUrl: 'http://test', client: client);

      final feed = await api.fetchFeed(groupId: 'g1', token: 'tok-123');

      expect(captured.headers['Authorization'], 'Bearer tok-123');
      expect(captured.url.toString(), 'http://test/groups/g1/feed');
      expect(feed.isEmpty, true);
    });

    test('createRide posts the request and parses the new ride', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return _json({
          'id': 'r1',
          'group_id': 'g1',
          'status': 'open',
          'passenger': {'id': 'm1', 'display_name': 'Troy'},
          'targets': [
            {'id': 'm2', 'display_name': 'Wendel'},
            {'id': 'm4', 'display_name': 'Grandma'},
          ],
          'pickup': {
            'id': 'p1',
            'group_id': 'g1',
            'name': 'The Pier',
            'lat': 38.9,
            'lng': -75.1,
          },
          'dropoff': {
            'id': 'p2',
            'group_id': 'g1',
            'name': "Grandma's",
            'lat': 38.8,
            'lng': -75.0,
          },
          'party_size': 2,
          'party': [
            {'id': 'm3', 'display_name': 'Emily'},
          ],
          'offer': '🍪 cookies',
          'scheduled_for': '2027-07-04T18:30:00Z',
          'created_at': '2027-07-04T17:00:00Z',
        });
      });
      final api = ApiClient(baseUrl: 'http://test', client: client);

      final ride = await api.createRide(
        groupId: 'g1',
        token: 'tok-123',
        pickupId: 'p1',
        dropoffId: 'p2',
        targetIds: const ['m2', 'm4'],
        partySize: 2,
        offer: '🍪 cookies',
        scheduledFor: DateTime.utc(2027, 7, 4, 18, 30),
        partyMemberIds: const ['m3'],
      );

      expect(captured.headers['Authorization'], 'Bearer tok-123');
      expect(captured.url.toString(), 'http://test/groups/g1/rides');

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['pickup_id'], 'p1');
      expect(body['dropoff_id'], 'p2');
      // Everyone being asked goes out as a set.
      expect(body['target_ids'], ['m2', 'm4']);
      expect(body['party_size'], 2);
      expect(body['offer'], '🍪 cookies');
      // Times go out as UTC instants — the server speaks UTC.
      expect(body['scheduled_for'], '2027-07-04T18:30:00.000Z');
      expect(body['party_member_ids'], ['m3']);

      expect(ride.id, 'r1');
      expect(ride.status, 'open');
      expect(ride.targets.map((t) => t.displayName), ['Wendel', 'Grandma']);
      expect(ride.pickup.name, 'The Pier');
      expect(ride.dropoff.name, "Grandma's");
      expect(ride.partySize, 2);
      expect(ride.party.single.displayName, 'Emily');
      // The offer survives the round trip intact — the server sends UTF-8 with
      // no charset, and a naive read would turn the emoji into mojibake.
      expect(ride.offer, '🍪 cookies');
      expect(ride.isScheduled, true);
      expect(ride.scheduledFor!.toUtc(), DateTime.utc(2027, 7, 4, 18, 30));
    });

    test('createRide omits a scheduled time for a "now" ride', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return _json({
          'id': 'r1',
          'group_id': 'g1',
          'status': 'open',
          'passenger': {'id': 'm1', 'display_name': 'Troy'},
          'targets': [
            {'id': 'm2', 'display_name': 'Wendel'},
          ],
          'pickup': {
            'id': 'p1',
            'group_id': 'g1',
            'name': 'The Pier',
            'lat': 38.9,
            'lng': -75.1,
          },
          'dropoff': {
            'id': 'p2',
            'group_id': 'g1',
            'name': "Grandma's",
            'lat': 38.8,
            'lng': -75.0,
          },
          'party_size': 1,
          'party': <dynamic>[],
          'offer': null,
          'scheduled_for': null,
          'created_at': '2027-07-04T17:00:00Z',
        });
      });
      final api = ApiClient(baseUrl: 'http://test', client: client);

      final ride = await api.createRide(
        groupId: 'g1',
        token: 'tok-123',
        pickupId: 'p1',
        dropoffId: 'p2',
        targetIds: const ['m2'],
      );

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      // Party size defaults to "just me", and no time means "now".
      expect(body['party_size'], 1);
      expect(body['scheduled_for'], isNull);

      expect(ride.isScheduled, false);
      expect(ride.offer, isNull);
      expect(ride.party, isEmpty);
    });

    test('fetchRoster sends the bearer token and parses the members', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'group_id': 'g1',
            'members': [
              {'id': 'm1', 'display_name': 'Troy', 'is_admin': true},
              {'id': 'm2', 'display_name': 'Wendel', 'is_admin': false},
            ],
          }),
          200,
        );
      });
      final api = ApiClient(baseUrl: 'http://test', client: client);

      final roster = await api.fetchRoster(groupId: 'g1', token: 'tok-123');

      expect(captured.headers['Authorization'], 'Bearer tok-123');
      expect(captured.url.toString(), 'http://test/groups/g1/members');
      expect(roster.members.map((m) => m.displayName), ['Troy', 'Wendel']);
      expect(roster.members.map((m) => m.isAdmin), [true, false]);
      // You can't ping yourself for a ride, so the roster can leave you out.
      expect(roster.othersThan('m1').map((m) => m.id), ['m2']);
    });

    test(
      'non-2xx becomes an ApiException carrying the server message',
      () async {
        final client = MockClient((req) async {
          return http.Response(
            jsonEncode({'error': 'missing or invalid token'}),
            401,
          );
        });
        final api = ApiClient(baseUrl: 'http://test', client: client);

        expect(
          () => api.fetchFeed(groupId: 'g1', token: 'bad'),
          throwsA(
            isA<ApiException>()
                .having((e) => e.statusCode, 'statusCode', 401)
                .having(
                  (e) => e.message,
                  'message',
                  'missing or invalid token',
                ),
          ),
        );
      },
    );
  });

  group('ApiClient places', () {
    String placesBody() => jsonEncode({
      'group_id': 'g1',
      'places': [
        {
          'id': 'p1',
          'group_id': 'g1',
          'name': "Grandma's",
          'lat': 38.8,
          'lng': -75.0,
        },
      ],
    });

    test('fetchPlaces sends the bearer token and parses the list', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(placesBody(), 200);
      });
      final api = ApiClient(baseUrl: 'http://test', client: client);

      final places = await api.fetchPlaces(groupId: 'g1', token: 'tok-123');

      expect(captured.method, 'GET');
      expect(captured.url.toString(), 'http://test/groups/g1/places');
      expect(captured.headers['Authorization'], 'Bearer tok-123');
      expect(places.places.single.name, "Grandma's");
      expect(places.places.single.lat, 38.8);
    });

    test('createPlace posts name + coordinates with the token', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(placesBody(), 200);
      });
      final api = ApiClient(baseUrl: 'http://test', client: client);

      await api.createPlace(
        groupId: 'g1',
        token: 'tok-123',
        name: 'The Pier',
        lat: 38.9,
        lng: -75.1,
      );

      expect(captured.method, 'POST');
      expect(captured.url.toString(), 'http://test/groups/g1/places');
      expect(captured.headers['Authorization'], 'Bearer tok-123');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['name'], 'The Pier');
      expect(body['lat'], 38.9);
      expect(body['lng'], -75.1);
    });

    test('updatePlace puts to the place path', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(placesBody(), 200);
      });
      final api = ApiClient(baseUrl: 'http://test', client: client);

      await api.updatePlace(
        groupId: 'g1',
        token: 'tok-123',
        placeId: 'p1',
        name: 'Renamed',
        lat: 1.0,
        lng: 2.0,
      );

      expect(captured.method, 'PUT');
      expect(captured.url.toString(), 'http://test/groups/g1/places/p1');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['name'], 'Renamed');
    });

    test('deletePlace deletes the place path with the token', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode({'group_id': 'g1', 'places': []}), 200);
      });
      final api = ApiClient(baseUrl: 'http://test', client: client);

      final places = await api.deletePlace(
        groupId: 'g1',
        token: 'tok-123',
        placeId: 'p1',
      );

      expect(captured.method, 'DELETE');
      expect(captured.url.toString(), 'http://test/groups/g1/places/p1');
      expect(captured.headers['Authorization'], 'Bearer tok-123');
      expect(places.isEmpty, true);
    });

    test('copyPlaces posts the source group id', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(placesBody(), 200);
      });
      final api = ApiClient(baseUrl: 'http://test', client: client);

      await api.copyPlaces(groupId: 'g1', token: 'tok-123', fromGroupId: 'g0');

      expect(captured.method, 'POST');
      expect(captured.url.toString(), 'http://test/groups/g1/places/copy');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['from_group_id'], 'g0');
    });

    test('a rejected mutation surfaces the server message', () async {
      final client = MockClient((req) async {
        return http.Response(jsonEncode({'error': 'forbidden'}), 403);
      });
      final api = ApiClient(baseUrl: 'http://test', client: client);

      expect(
        () => api.createPlace(
          groupId: 'g1',
          token: 'tok-123',
          name: 'X',
          lat: 0,
          lng: 0,
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.message, 'message', 'forbidden'),
        ),
      );
    });
  });
}
