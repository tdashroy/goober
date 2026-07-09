import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Thrown when the server returns a non-2xx response. Carries the status and
/// the server's error message so the UI can show something friendly.
class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Talks to the Goober server over HTTP.
///
/// Both the [baseUrl] and the underlying [http.Client] are injected so tests can
/// point it at a mock client with no real network, and so the emulator can reach
/// the dev-machine server (default host alias `10.0.2.2`, see [defaultBaseUrl]).
class ApiClient {
  ApiClient({String? baseUrl, http.Client? client})
    : baseUrl = baseUrl ?? defaultBaseUrl,
      _client = client ?? http.Client();

  /// On the Android emulator, the host machine's loopback is reachable at
  /// `10.0.2.2`. Override at build time with `--dart-define=GOOBER_API_BASE=...`.
  static const String defaultBaseUrl = String.fromEnvironment(
    'GOOBER_API_BASE',
    defaultValue: 'http://10.0.2.2:8080',
  );

  final String baseUrl;
  final http.Client _client;

  /// Create a group; the caller becomes its admin. Returns the new [Session].
  Future<Session> createGroup({
    required String groupName,
    required String name,
    required String phone,
  }) async {
    final resp = await _client.post(
      Uri.parse('$baseUrl/groups'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'group_name': groupName, 'name': name, 'phone': phone}),
    );
    return Session.fromJson(_decode(resp));
  }

  /// Join an existing group by id. Re-joining with the same phone re-attaches
  /// the existing identity server-side. Returns the [Session].
  Future<Session> joinGroup({
    required String groupId,
    required String name,
    required String phone,
  }) async {
    final resp = await _client.post(
      Uri.parse('$baseUrl/groups/$groupId/join'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'name': name, 'phone': phone}),
    );
    return Session.fromJson(_decode(resp));
  }

  /// Fetch the group's activity feed. Requires the bearer [token]; the server
  /// rejects the request without a valid one.
  Future<Feed> fetchFeed({
    required String groupId,
    required String token,
  }) async {
    final resp = await _client.get(
      Uri.parse('$baseUrl/groups/$groupId/feed'),
      headers: _authHeaders(token),
    );
    return Feed.fromJson(_decode(resp));
  }

  Map<String, String> _authHeaders(String token) => {
    'Authorization': 'Bearer $token',
  };

  /// Decode a JSON response, converting non-2xx into an [ApiException].
  Map<String, dynamic> _decode(http.Response resp) {
    final Map<String, dynamic> body = resp.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final message = (body['error'] as String?) ?? 'request failed';
      throw ApiException(resp.statusCode, message);
    }
    return body;
  }

  void close() => _client.close();
}
