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
}
