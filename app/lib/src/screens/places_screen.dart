import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';

/// The group's places — houses and landmarks — as everyone in the group sees
/// them: a plain, read-only list.
///
/// This is the screen a member opens to answer "where can I get a ride to?", so
/// it carries no management affordances at all — no adding, editing, deleting or
/// copying, not even greyed out. Admins see this same list; they change it from
/// the admin area's places management instead.
class PlacesScreen extends StatefulWidget {
  const PlacesScreen({
    super.key,
    required this.api,
    required this.session,
    this.onUnauthenticated,
  });

  final ApiClient api;
  final Session session;

  /// Called if a request comes back 401 (a stale persisted token), so the app
  /// can drop the token and return to onboarding rather than looping.
  final VoidCallback? onUnauthenticated;

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  late Future<Places> _placesFuture = _load();

  Future<Places> _load() => loadPlaces(
    api: widget.api,
    session: widget.session,
    onUnauthenticated: widget.onUnauthenticated,
  );

  void _reload() => setState(() {
    _placesFuture = _load();
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Places')),
      body: FutureBuilder<Places>(
        future: _placesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return PlacesError(error: snapshot.error, onRetry: _reload);
          }
          final places = snapshot.data;
          if (places == null || places.isEmpty) {
            return const EmptyPlaces(
              message: "Your group's admin hasn't added any places yet.",
            );
          }
          return ListView.separated(
            itemCount: places.places.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final place = places.places[i];
              return ListTile(
                key: Key('place-${place.id}'),
                leading: const Icon(Icons.place, color: GooberColors.coral),
                title: Text(place.name),
                subtitle: Text(formatPlaceCoords(place.lat, place.lng)),
              );
            },
          );
        },
      ),
    );
  }
}

/// Fetches the group's places, routing a 401 (a stale persisted token) back to
/// onboarding on the way out so the app doesn't loop on a failing request.
Future<Places> loadPlaces({
  required ApiClient api,
  required Session session,
  VoidCallback? onUnauthenticated,
}) async {
  try {
    return await api.fetchPlaces(
      groupId: session.groupId,
      token: session.token,
    );
  } on ApiException catch (e) {
    if (e.statusCode == 401) onUnauthenticated?.call();
    rethrow;
  }
}

/// Coordinates are shown as plain latitude/longitude numbers for now. A richer
/// drop-a-pin-on-a-map view is deliberately deferred — the data it would need is
/// already here.
String formatPlaceCoords(double lat, double lng) =>
    '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';

/// Friendly empty state. The [message] says what to do next, which differs by
/// who is looking: an admin managing the list is nudged to add the first place,
/// while a member browsing it is told there is nothing to browse yet.
class EmptyPlaces extends StatelessWidget {
  const EmptyPlaces({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('📍', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 16),
            const Text(
              'No places yet',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: GooberColors.ink),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the places list can't be fetched, with a way to try again.
class PlacesError extends StatelessWidget {
  const PlacesError({super.key, required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is ApiException
        ? (error as ApiException).message
        : "Couldn't reach Goober";
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('😵', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
