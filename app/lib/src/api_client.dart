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

  /// Sign in as one of the people the server's dev seed profile created, named by
  /// their [memberKey] (`bob`, `grandma`). Returns their [Session] — the same
  /// shape a real join returns, carrying the token they already hold.
  ///
  /// Only a server built with its dev-seed feature serves this route, and it only
  /// resolves seeded people; against any other server the call fails. Callers
  /// must gate it to debug builds (see `DevLogin`).
  Future<Session> devSession({required String memberKey}) async {
    final resp = await _client.get(Uri.parse('$baseUrl/dev/session/$memberKey'));
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

  /// Fetch the group's curated places. Any member may read; requires [token].
  Future<Places> fetchPlaces({
    required String groupId,
    required String token,
  }) async {
    final resp = await _client.get(
      Uri.parse('$baseUrl/groups/$groupId/places'),
      headers: _authHeaders(token),
    );
    return Places.fromJson(_decode(resp));
  }

  /// Create a place. Admin only (the server rejects non-admins). Returns the
  /// group's full, updated place list.
  Future<Places> createPlace({
    required String groupId,
    required String token,
    required String name,
    required double lat,
    required double lng,
  }) async {
    final resp = await _client.post(
      Uri.parse('$baseUrl/groups/$groupId/places'),
      headers: _jsonAuthHeaders(token),
      body: jsonEncode({'name': name, 'lat': lat, 'lng': lng}),
    );
    return Places.fromJson(_decode(resp));
  }

  /// Rename and/or move a place. Admin only. Returns the updated place list.
  Future<Places> updatePlace({
    required String groupId,
    required String token,
    required String placeId,
    required String name,
    required double lat,
    required double lng,
  }) async {
    final resp = await _client.put(
      Uri.parse('$baseUrl/groups/$groupId/places/$placeId'),
      headers: _jsonAuthHeaders(token),
      body: jsonEncode({'name': name, 'lat': lat, 'lng': lng}),
    );
    return Places.fromJson(_decode(resp));
  }

  /// Delete a place. Admin only. Returns the updated place list.
  Future<Places> deletePlace({
    required String groupId,
    required String token,
    required String placeId,
  }) async {
    final resp = await _client.delete(
      Uri.parse('$baseUrl/groups/$groupId/places/$placeId'),
      headers: _authHeaders(token),
    );
    return Places.fromJson(_decode(resp));
  }

  /// Seed this group's places from another group's list (the "copy last year's
  /// places" starting point). Admin only. Returns the updated place list.
  Future<Places> copyPlaces({
    required String groupId,
    required String token,
    required String fromGroupId,
  }) async {
    final resp = await _client.post(
      Uri.parse('$baseUrl/groups/$groupId/places/copy'),
      headers: _jsonAuthHeaders(token),
      body: jsonEncode({'from_group_id': fromGroupId}),
    );
    return Places.fromJson(_decode(resp));
  }

  Map<String, String> _authHeaders(String token) => {
    'Authorization': 'Bearer $token',
  };

  Map<String, String> _jsonAuthHeaders(String token) => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
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
