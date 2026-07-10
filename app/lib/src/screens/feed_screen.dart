import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';
import 'places_screen.dart';

/// The front door: the group's live activity feed with a big
/// "Get a ride" button on top.
///
/// In the walking skeleton the feed is always empty, so this renders a friendly
/// empty state. The "Get a ride" button is a non-functional placeholder — the
/// ride-request flow comes later.
class FeedScreen extends StatefulWidget {
  const FeedScreen({
    super.key,
    required this.api,
    required this.session,
    required this.onUnauthenticated,
  });

  final ApiClient api;
  final Session session;

  /// Called when the feed request comes back 401, i.e. the persisted token is
  /// stale (common in local dev where the server DB is wiped between runs). The
  /// app clears the token and returns to onboarding instead of looping on the
  /// same failing request.
  final VoidCallback onUnauthenticated;

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  late Future<Feed> _feedFuture;

  @override
  void initState() {
    super.initState();
    _feedFuture = _load();
  }

  Future<Feed> _load() async {
    try {
      return await widget.api.fetchFeed(
        groupId: widget.session.groupId,
        token: widget.session.token,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        widget.onUnauthenticated();
      }
      rethrow;
    }
  }

  void _reload() => setState(() => _feedFuture = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.session.groupName.isEmpty
              ? 'Goober'
              : widget.session.groupName,
        ),
        actions: [
          IconButton(
            key: const Key('open-places-button'),
            icon: const Icon(Icons.place),
            tooltip: 'Places',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlacesScreen(
                    api: widget.api,
                    session: widget.session,
                    onUnauthenticated: widget.onUnauthenticated,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _GetARideButton(),
          Expanded(
            child: FutureBuilder<Feed>(
              future: _feedFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return _FeedError(error: snapshot.error, onRetry: _reload);
                }
                final feed = snapshot.data;
                if (feed == null || feed.isEmpty) {
                  return const EmptyFeed();
                }
                // Rides aren't implemented yet; the skeleton only ever hits the
                // empty state above.
                return const EmptyFeed();
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The big "Get a ride" button (placeholder for the real ride flow).
class _GetARideButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.infinity,
        height: 64,
        child: FilledButton.icon(
          key: const Key('get-a-ride-button'),
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Ride requests are coming soon 🚧')),
            );
          },
          style: FilledButton.styleFrom(
            backgroundColor: GooberColors.cartTeal,
            textStyle: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          icon: const Icon(Icons.directions_car, size: 28),
          label: const Text('Get a ride'),
        ),
      ),
    );
  }
}

/// Friendly empty-feed state shown when nobody has a ride going.
class EmptyFeed extends StatelessWidget {
  const EmptyFeed({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Text('🥜', style: TextStyle(fontSize: 56)),
            SizedBox(height: 16),
            Text(
              'All quiet on the boardwalk',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              "No rides going right now. Tap “Get a ride” to round up a cart.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: GooberColors.ink),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeedError extends StatelessWidget {
  const _FeedError({required this.error, required this.onRetry});

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
