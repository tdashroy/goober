import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goober/src/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
