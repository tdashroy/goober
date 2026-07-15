import 'dart:convert';

import 'package:http/http.dart' as http;

import 'feed_stream.dart';
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
    final resp = await _client.get(
      Uri.parse('$baseUrl/dev/session/$memberKey'),
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

  /// Open the group's live feed stream: one Server-Sent Events connection that
  /// pushes a [FeedEvent] for every change the feed reflects — a new request, an
  /// answer, a lifecycle step — so an open board updates itself without polling.
  ///
  /// This is the live overlay only; the initial board still comes from
  /// [fetchFeed], which stays the source of truth. Same auth and group-scoping as
  /// the feed: a non-2xx (401/403) throws an [ApiException] just like the REST
  /// calls. The returned stream ends when the connection drops — [LiveFeed] wraps
  /// this with reconnection.
  Stream<FeedEvent> streamFeed({
    required String groupId,
    required String token,
  }) async* {
    final request = http.Request(
      'GET',
      Uri.parse('$baseUrl/groups/$groupId/feed/stream'),
    );
    request.headers['Authorization'] = 'Bearer $token';
    request.headers['Accept'] = 'text/event-stream';

    final resp = await _client.send(request);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      // Drain the body so the connection is released, then surface the failure
      // the same way the REST decode does.
      await resp.stream.drain<void>();
      throw ApiException(resp.statusCode, 'feed stream failed');
    }

    // The server sends UTF-8; decode explicitly rather than trusting a default.
    final lines = resp.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final message in parseServerSentEvents(lines)) {
      final event = _feedEventFrom(message);
      if (event != null) yield event;
    }
  }

  /// Map one parsed SSE message to a [FeedEvent], or null for one this build
  /// doesn't recognise — a newer server may send event kinds this app hasn't
  /// heard of, and one unknown line shouldn't break the stream.
  FeedEvent? _feedEventFrom(SseMessage message) {
    switch (message.event) {
      case 'ride':
        try {
          final json = jsonDecode(message.data) as Map<String, dynamic>;
          return RideChanged(
            Ride.fromJson(json['ride'] as Map<String, dynamic>),
          );
        } catch (_) {
          return null;
        }
      case 'resync':
        return const FeedResync();
      default:
        return null;
    }
  }

  /// Fetch the group roster — everyone in the group, i.e. everyone the caller
  /// can ping for a ride. Requires [token].
  Future<Roster> fetchRoster({
    required String groupId,
    required String token,
  }) async {
    final resp = await _client.get(
      Uri.parse('$baseUrl/groups/$groupId/members'),
      headers: _authHeaders(token),
    );
    return Roster.fromJson(_decode(resp));
  }

  /// Request a ride from [pickupId] to [dropoffId] — both curated places — as a
  /// ping to [targetIds], the members being asked to drive. At least one; the
  /// server rejects an empty set, a duplicate, and the passenger themselves.
  ///
  /// [partySize] counts everyone riding, including the passenger (1 = "just
  /// me"). [offer] is free text and optional. [scheduledFor] null means "now";
  /// otherwise it must be in the future and is sent as a UTC instant, since the
  /// server speaks UTC. [partyMemberIds] optionally tags who else is riding.
  ///
  /// Returns the newly created [Ride], which is `open` and visible to the whole
  /// group in the feed.
  Future<Ride> createRide({
    required String groupId,
    required String token,
    required String pickupId,
    required String dropoffId,
    required List<String> targetIds,
    int partySize = 1,
    String? offer,
    DateTime? scheduledFor,
    List<String> partyMemberIds = const [],
  }) async {
    final resp = await _client.post(
      Uri.parse('$baseUrl/groups/$groupId/rides'),
      headers: _jsonAuthHeaders(token),
      body: jsonEncode({
        'pickup_id': pickupId,
        'dropoff_id': dropoffId,
        'target_ids': targetIds,
        'party_size': partySize,
        'offer': offer,
        'scheduled_for': scheduledFor?.toUtc().toIso8601String(),
        'party_member_ids': partyMemberIds,
      }),
    );
    return Ride.fromJson(_decode(resp));
  }

  /// Move a ride along: answer a ping, mark the arrival, or close the ride out.
  ///
  /// The server decides whether the step is legal — from where the ride is and
  /// who is asking — so this is a request, not an assertion. A step out of turn
  /// (arriving before anyone accepted, accepting a ride somebody else already
  /// claimed) comes back `409`; a step by the wrong person comes back `403`.
  ///
  /// [personId] names the roster member an answer points at: who took the cart
  /// ([RideAction.noCart], optional) or who is coming instead
  /// ([RideAction.someoneElse], required). The other actions name nobody.
  ///
  /// Returns the ride as it now stands.
  Future<Ride> rideAction({
    required String groupId,
    required String token,
    required String rideId,
    required RideAction action,
    String? personId,
  }) async {
    final resp = await _client.post(
      Uri.parse('$baseUrl/groups/$groupId/rides/$rideId/actions'),
      headers: _jsonAuthHeaders(token),
      body: jsonEncode({'action': action.wire, 'person_id': personId}),
    );
    return Ride.fromJson(_decode(resp));
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
  ///
  /// Decodes the bytes as UTF-8 rather than reading `resp.body`: the server
  /// sends `application/json` with no `charset`, and `http` falls back to
  /// latin1 for that, which mangles every non-ASCII character. Goober is full of
  /// them — a "🍪 cookies" offer, a name with an accent — so read UTF-8, which is
  /// what the server actually sends.
  Map<String, dynamic> _decode(http.Response resp) {
    final Map<String, dynamic> body = resp.bodyBytes.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final message = (body['error'] as String?) ?? 'request failed';
      throw ApiException(resp.statusCode, message);
    }
    return body;
  }

  void close() => _client.close();
}
