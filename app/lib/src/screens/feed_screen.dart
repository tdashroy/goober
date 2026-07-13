import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';
import '../time_format.dart';
import 'admin_screen.dart';
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

  /// The roster, once anyone has needed it. Answering "I don't have a cart" or
  /// "someone else will come" means naming a person, and a name has to be
  /// someone real — but that's the only thing the board wants it for, so it is
  /// fetched on the first tap rather than on every poll.
  Roster? _roster;
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

  void _open(WidgetBuilder screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: screen));

  /// Everyone in the group, for naming who took your cart or who's coming
  /// instead. Fetched once, on the first answer that needs a name; if it can't
  /// be had, the picker simply has nobody in it rather than the card breaking.
  Future<List<RosterMember>> _loadRoster() async {
    final cached = _roster;
    if (cached != null) return cached.members;
    try {
      final roster = await widget.api.fetchRoster(
        groupId: widget.session.groupId,
        token: widget.session.token,
      );
      _roster = roster;
      return roster.members;
    } catch (_) {
      return const [];
    }
  }

  /// Take a step on a ride: answer a ping, mark the arrival, close it out.
  ///
  /// The server is the one that decides whether the step is legal, so a refusal
  /// is news — "someone else already took this ride" — and worth saying out
  /// loud. Either way the board is refetched: whatever the server thinks, that's
  /// what the ride is.
  Future<void> _act(Ride ride, RideAction action, {String? personId}) async {
    try {
      await widget.api.rideAction(
        groupId: widget.session.groupId,
        token: widget.session.token,
        rideId: ride.id,
        action: action,
        personId: personId,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 401) widget.onUnauthenticated();
      _say(e.message);
    } catch (_) {
      _say("Couldn't reach Goober. Try again.");
    }
    if (mounted) await _refresh();
  }

  /// Ask the person a driver's answer pointed at — the one who took the cart, or
  /// the one coming instead — for a ride, in one tap.
  ///
  /// It's the same route, party and offer as the ride they're being named on:
  /// the passenger still wants exactly the ride they asked for, just from
  /// somebody who can come. So it goes out as a fresh request, pinging them.
  Future<void> _askPerson(Ride ride, MemberRef person) async {
    try {
      await widget.api.createRide(
        groupId: widget.session.groupId,
        token: widget.session.token,
        pickupId: ride.pickup.id,
        dropoffId: ride.dropoff.id,
        targetIds: [person.id],
        partySize: ride.partySize,
        offer: ride.offer,
        // Carry the pickup time over only while it's still ahead of us — a time
        // that has since passed would be rejected, and "now" is what the
        // passenger means by then anyway.
        scheduledFor: (ride.scheduledFor?.isAfter(DateTime.now()) ?? false)
            ? ride.scheduledFor
            : null,
        partyMemberIds: ride.party.map((m) => m.id).toList(),
      );
      _say('Asked ${person.displayName} for a ride.');
    } on ApiException catch (e) {
      if (e.statusCode == 401) widget.onUnauthenticated();
      _say(e.message);
    } catch (_) {
      _say("Couldn't reach Goober. Try again.");
    }
    if (mounted) await _refresh();
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
          // Everyone can browse the group's places — you need to know where you
          // can be taken before you can ask for a ride there. The list opens
          // read-only for everyone, admins included; curating it lives behind
          // the admin door below.
          _AppBarAction(
            key: const Key('open-places-button'),
            icon: Icons.place_outlined,
            label: 'Places',
            onPressed: () => _open(
              (_) => PlacesScreen(
                api: widget.api,
                session: widget.session,
                onUnauthenticated: widget.onUnauthenticated,
              ),
            ),
          ),
          // Admins additionally get one labeled door into everything they can
          // administer. A bare icon read as neither "administration" nor
          // "admin-only", so it says so in words, and members never see it.
          if (widget.session.member.isAdmin)
            _AppBarAction(
              key: const Key('open-admin-button'),
              icon: Icons.shield_outlined,
              label: 'Admin',
              onPressed: () => _open(
                (_) => AdminScreen(
                  api: widget.api,
                  session: widget.session,
                  onUnauthenticated: widget.onUnauthenticated,
                ),
              ),
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
        itemBuilder: (context, i) {
          final ride = feed.rides[i];
          return RideCard(
            ride: ride,
            viewerId: widget.session.member.id,
            loadRoster: _loadRoster,
            onAction: (action, {personId}) =>
                _act(ride, action, personId: personId),
            onAskPerson: (person) => _askPerson(ride, person),
          );
        },
      ),
    );
  }
}

/// An app-bar destination that says in words where it goes. Icon-only actions
/// left people guessing what they opened, so every entry here carries a label.
class _AppBarAction extends StatelessWidget {
  const _AppBarAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: TextButton.icon(
        icon: Icon(icon),
        label: Text(label),
        style: TextButton.styleFrom(foregroundColor: GooberColors.ink),
        onPressed: onPressed,
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
/// they're offering, who they asked — and what those people said back.
///
/// The card is also where a ride is *driven*, so what it offers depends on who
/// is looking at it. Someone who was pinged, while the ride is still going
/// begging, gets the four-option menu. The driver who claimed it gets "I'm
/// here", then the driver and the passenger both get "Delivered". Everyone else
/// is watching, which is half the fun.
class RideCard extends StatelessWidget {
  const RideCard({
    super.key,
    required this.ride,
    required this.viewerId,
    required this.loadRoster,
    required this.onAction,
    required this.onAskPerson,
  });

  final Ride ride;

  /// Who is looking. The card shows them their own part in the ride, if they
  /// have one.
  final String viewerId;

  /// The group, for naming who took your cart or who's coming instead. A lead is
  /// a person, never typed-in text — that's what makes it tappable. Fetched only
  /// when an answer actually needs a name.
  final Future<List<RosterMember>> Function() loadRoster;

  /// Ask the server to move the ride along.
  final void Function(RideAction action, {String? personId}) onAction;

  /// Ask the person a driver's answer named for a ride, in one tap.
  final void Function(MemberRef person) onAskPerson;

  /// Only the passenger can act on a lead: it's their ride to re-ask for.
  bool get _viewerIsPassenger => ride.passenger.id == viewerId;

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

            // Where the ride has got to, once it's got anywhere.
            if (_statusLine() case final status?) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(status.icon, size: 18, color: GooberColors.cartTeal),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      status.text,
                      key: Key('ride-status-${ride.id}'),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ],

            // What the people asked have said back — including the "no"s, which
            // are the ones that hand the passenger somewhere else to look.
            for (final response in ride.responses)
              if (response.response != RideAction.onMyWay)
                _ResponseLine(
                  text: _responseText(response),
                  // A lead is only actionable by the person whose ride it is.
                  person: _viewerIsPassenger ? response.person : null,
                  rideId: ride.id,
                  onAskPerson: onAskPerson,
                ),

            ..._actions(context),
          ],
        ),
      ),
    );
  }

  /// The one line that says where the ride is — nothing while it's still open
  /// and waiting on an answer, since the card already says who was asked.
  ({IconData icon, String text})? _statusLine() {
    final driver = ride.driver?.displayName;
    return switch (ride.status) {
      RideStatus.accepted => (
        icon: Icons.directions_car,
        text: '$driver is on the way',
      ),
      RideStatus.arrived => (icon: Icons.waving_hand, text: '$driver is here'),
      RideStatus.delivered => (
        icon: Icons.check_circle,
        text: 'Delivered by $driver 🎉',
      ),
      _ => null,
    };
  }

  /// One answer, as a sentence. The "no"s say what they know: who has the cart,
  /// who's coming instead.
  String _responseText(RideResponse r) {
    final who = r.member.displayName;
    final named = r.person?.displayName;
    return switch (r.response) {
      RideAction.onMyWay => '$who is coming',
      RideAction.cantRightNow => "$who can't right now",
      RideAction.noCart =>
        named == null
            ? "$who doesn't have a cart"
            : "$who doesn't have a cart — $named took it",
      RideAction.someoneElse => '$who says $named will come',
      // Arriving and delivering aren't answers to a ping; they're the ride
      // moving, and the status line above says so.
      RideAction.arrived || RideAction.delivered => '$who answered',
    };
  }

  /// What this particular person can do about this particular ride, right now.
  List<Widget> _actions(BuildContext context) {
    if (ride.canAnswer(viewerId)) {
      return [const SizedBox(height: 12), _responseMenu(context)];
    }
    if (ride.canMarkArrived(viewerId)) {
      return [
        const SizedBox(height: 12),
        _RideButton(
          buttonKey: Key('ride-arrived-${ride.id}'),
          icon: Icons.waving_hand,
          label: "I'm here",
          onPressed: () => onAction(RideAction.arrived),
        ),
      ];
    }
    if (ride.canMarkDelivered(viewerId)) {
      return [
        const SizedBox(height: 12),
        _RideButton(
          buttonKey: Key('ride-delivered-${ride.id}'),
          icon: Icons.check_circle,
          label: 'Delivered 🎉',
          onPressed: () => onAction(RideAction.delivered),
        ),
      ];
    }
    return const [];
  }

  /// The four answers to a ping. Not a yes/no: the three "no"s each say
  /// something different, and two of them can point the passenger somewhere.
  Widget _responseMenu(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          key: Key('ride-on-my-way-${ride.id}'),
          style: FilledButton.styleFrom(backgroundColor: GooberColors.cartTeal),
          onPressed: () => onAction(RideAction.onMyWay),
          icon: const Icon(Icons.directions_car, size: 18),
          label: const Text('On my way'),
        ),
        OutlinedButton(
          key: Key('ride-cant-${ride.id}'),
          onPressed: () => onAction(RideAction.cantRightNow),
          child: const Text("Can't right now"),
        ),
        OutlinedButton(
          key: Key('ride-no-cart-${ride.id}'),
          onPressed: () => _answerNoCart(context),
          child: const Text("I don't have a cart"),
        ),
        OutlinedButton(
          key: Key('ride-someone-else-${ride.id}'),
          onPressed: () => _answerSomeoneElse(context),
          child: const Text('Someone else will come'),
        ),
      ],
    );
  }

  /// "I don't have a cart" — and, if you know, who took it. You needn't know:
  /// the answer stands on its own.
  Future<void> _answerNoCart(BuildContext context) async {
    final choice = await _pickPerson(
      context,
      title: 'Who has your cart?',
      // The one person who can't have taken your cart is the one waiting on it.
      nobody: "I don't know",
    );
    if (choice == null) return;
    onAction(RideAction.noCart, personId: choice.person?.id);
  }

  /// "Someone else will come" — which is only worth saying if it says who.
  Future<void> _answerSomeoneElse(BuildContext context) async {
    final choice = await _pickPerson(context, title: "Who's coming instead?");
    final person = choice?.person;
    if (person == null) return;
    onAction(RideAction.someoneElse, personId: person.id);
  }

  /// Name someone from the roster. Returns null if the person backed out, so
  /// dismissing the picker cancels the answer rather than sending a vaguer one.
  Future<_PersonChoice?> _pickPerson(
    BuildContext context, {
    required String title,
    String? nobody,
  }) async {
    final roster = await loadRoster();
    if (!context.mounted) return null;

    // Neither you (you're the one without a cart) nor the passenger (they're the
    // one waiting for it) can be the answer.
    final candidates =
        roster
            .where((m) => m.id != viewerId && m.id != ride.passenger.id)
            .toList()
          ..sort(
            (a, b) => a.displayName.toLowerCase().compareTo(
              b.displayName.toLowerCase(),
            ),
          );

    return showDialog<_PersonChoice>(
      context: context,
      builder: (context) => SimpleDialog(
        key: const Key('person-picker'),
        title: Text(title),
        children: [
          for (final member in candidates)
            SimpleDialogOption(
              key: Key('pick-person-${member.id}'),
              onPressed: () => Navigator.of(context).pop(
                _PersonChoice(
                  MemberRef(id: member.id, displayName: member.displayName),
                ),
              ),
              child: Text(member.displayName),
            ),
          if (nobody != null)
            SimpleDialogOption(
              key: const Key('pick-person-nobody'),
              onPressed: () =>
                  Navigator.of(context).pop(const _PersonChoice(null)),
              child: Text(nobody),
            ),
        ],
      ),
    );
  }
}

/// The outcome of naming somebody: a person, or nobody in particular. Distinct
/// from `null`, which is the picker being dismissed — "I don't know who has it"
/// is an answer, backing out is not.
class _PersonChoice {
  const _PersonChoice(this.person);
  final MemberRef? person;
}

/// One driver's answer on the card, with the person it named — if the viewer is
/// the passenger — as a one-tap way to ask *them* instead.
class _ResponseLine extends StatelessWidget {
  const _ResponseLine({
    required this.text,
    required this.person,
    required this.rideId,
    required this.onAskPerson,
  });

  final String text;
  final MemberRef? person;
  final String rideId;
  final void Function(MemberRef person) onAskPerson;

  @override
  Widget build(BuildContext context) {
    final lead = person;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(text, style: const TextStyle(fontSize: 14)),
          if (lead != null)
            ActionChip(
              key: Key('ask-$rideId-${lead.id}'),
              avatar: const Icon(Icons.send, size: 16),
              label: Text('Ask ${lead.displayName}'),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onPressed: () => onAskPerson(lead),
            ),
        ],
      ),
    );
  }
}

/// The one thing the ride is waiting on this person to do.
class _RideButton extends StatelessWidget {
  const _RideButton({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton.icon(
        key: buttonKey,
        style: FilledButton.styleFrom(backgroundColor: GooberColors.cartTeal),
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label),
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
