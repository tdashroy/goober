import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';
import '../time_format.dart';
import 'places_screen.dart';
import 'request_ride_screen.dart';

/// The front door: the group's live activity feed with a big "Get a ride" button
/// on top.
///
/// The feed is shared, not personal — everyone in the group sees every ride, so
/// half the time the board answers your question before you ask it. "Get a ride"
/// opens the request flow; a new request lands here for the whole group.
class FeedScreen extends StatefulWidget {
  const FeedScreen({
    super.key,
    required this.api,
    required this.session,
    required this.onUnauthenticated,
  });

  /// How often the board quietly refetches, so a ride someone else just posted
  /// shows up without anyone pulling to refresh.
  static const Duration autoRefreshInterval = Duration(seconds: 30);

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
  Feed? _feed;
  Object? _error;
  bool _loading = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _reload();
    _refreshTimer = Timer.periodic(
      FeedScreen.autoRefreshInterval,
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// Full reload with the loading spinner: the first load, and retrying out of
  /// the error state. In-place updates go through [_refresh] instead.
  Future<void> _reload() {
    setState(() {
      _loading = true;
      _error = null;
    });
    return _refresh();
  }

  /// Refetch the feed and swap the new data in under the current board — no
  /// spinner over what's already showing. If a fetch fails while the board has
  /// content (say a poll hits a network blip), the content stays put.
  Future<void> _refresh() async {
    try {
      final feed = await widget.api.fetchFeed(
        groupId: widget.session.groupId,
        token: widget.session.token,
      );
      if (!mounted) return;
      setState(() {
        _feed = feed;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      final error = e;
      if (error is ApiException && error.statusCode == 401) {
        widget.onUnauthenticated();
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_feed == null) _error = error;
      });
    }
  }

  /// Open the request flow. It pops `true` once a ride has been asked for, which
  /// is the cue to pull the feed again so the new request is on the board.
  Future<void> _requestRide() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => RequestRideScreen(
          api: widget.api,
          session: widget.session,
          onUnauthenticated: widget.onUnauthenticated,
        ),
      ),
    );
    if (created == true && mounted) _refresh();
  }

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
          _GetARideButton(onPressed: _requestRide),
          Expanded(child: _buildBoard()),
        ],
      ),
    );
  }

  Widget _buildBoard() {
    final feed = _feed;
    if (feed == null) {
      if (_loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return _FeedError(error: _error, onRetry: _reload);
    }
    if (feed.isEmpty) {
      // The empty board is pullable too — someone staring at it is exactly the
      // person waiting for a new ride to show up.
      return RefreshIndicator(
        onRefresh: _refresh,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: const EmptyFeed(),
            ),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: feed.rides.length,
        itemBuilder: (context, i) => RideCard(ride: feed.rides[i]),
      ),
    );
  }
}

/// The big "Get a ride" button — the front door's one obvious action.
class _GetARideButton extends StatelessWidget {
  const _GetARideButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.infinity,
        height: 64,
        child: FilledButton.icon(
          key: const Key('get-a-ride-button'),
          onPressed: onPressed,
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

/// One ride on the shared board: who's going where, how many of them, what
/// they're offering, and who they asked.
class RideCard extends StatelessWidget {
  const RideCard({super.key, required this.ride});

  final Ride ride;

  @override
  Widget build(BuildContext context) {
    final asked = ride.targets.map((m) => m.displayName).join(', ');
    return Card(
      key: Key('ride-${ride.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Who asked, and everyone they pinged — one person, or a few. A ride
            // with nobody pinged would be a broadcast; today every request names
            // at least one person.
            Text(
              asked.isEmpty
                  ? '${ride.passenger.displayName} needs a ride'
                  : '${ride.passenger.displayName} → $asked',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            // The route: from → to.
            Row(
              children: [
                const Icon(Icons.place, size: 18, color: GooberColors.coral),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${ride.pickup.name} → ${ride.dropoff.name}',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _Tag(
                  icon: Icons.people,
                  // "Just me" reads better than "1 riding".
                  label: ride.partySize == 1
                      ? 'Just me'
                      : '${ride.partySize} riding',
                ),
                _Tag(
                  icon: ride.isScheduled ? Icons.schedule : Icons.bolt,
                  label: ride.isScheduled
                      ? formatRideTime(ride.scheduledFor!)
                      : 'Now',
                ),
              ],
            ),

            // The offer is free text and can run long, so it gets a wrapping
            // row of its own rather than a chip.
            if (ride.offer != null) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.card_giftcard,
                    size: 18,
                    color: GooberColors.ink,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      ride.offer!,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
            ],

            if (ride.party.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'With ${ride.party.map((m) => m.displayName).join(', ')}',
                style: const TextStyle(fontSize: 14),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A small labelled chip on a ride card — party size or timing.
class _Tag extends StatelessWidget {
  const _Tag({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16, color: GooberColors.ink),
      label: Text(label),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
