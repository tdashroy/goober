import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';
import '../time_format.dart';

/// The most people one request can claim; the server enforces the same cap.
const maxPartySize = 8;

/// Ask for a ride: pick a route from the group's curated places, say how many
/// are coming, offer something (or not), choose now-or-later, and ping the
/// people you want to come get you.
///
/// This is the **direct ping** flow: the passenger picks a set of members from
/// the roster — one person, or a few, whoever can come. Broadcasting to
/// "anyone?" is a separate path.
///
/// Pops `true` once the ride is created, so the feed behind it can refresh.
class RequestRideScreen extends StatefulWidget {
  const RequestRideScreen({
    super.key,
    required this.api,
    required this.session,
    this.onUnauthenticated,
    this.pickScheduledTime,
    this.pickScheduledDay,
  });

  final ApiClient api;
  final Session session;

  /// Called if a request comes back 401 (a stale persisted token), so the app
  /// can drop the token and return to onboarding rather than looping.
  final VoidCallback? onUnauthenticated;

  /// Asks the user for a pickup time, returning null if they back out. Injected
  /// so tests can drive scheduling without the platform time picker; defaults to
  /// the real Material one.
  final Future<TimeOfDay?> Function(BuildContext context, TimeOfDay initial)?
  pickScheduledTime;

  /// Asks the user which day the ride is for, returning null if they back out.
  /// Injected alongside [pickScheduledTime]; defaults to the Material date
  /// picker.
  final Future<DateTime?> Function(BuildContext context, DateTime initial)?
  pickScheduledDay;

  @override
  State<RequestRideScreen> createState() => _RequestRideScreenState();
}

/// What the screen needs before it can show the form: where you can go, and who
/// you can ask.
class _RideOptions {
  const _RideOptions({required this.places, required this.roster});
  final Places places;
  final Roster roster;
}

class _RequestRideScreenState extends State<RequestRideScreen> {
  late Future<_RideOptions> _optionsFuture;

  final _offer = TextEditingController();

  Place? _pickup;
  Place? _dropoff;
  int _partySize = 1;

  /// Who's being asked to drive: a set, in the order they were picked. At least
  /// one is required, and the passenger is never in it — you can't ask yourself.
  final Set<String> _targetIds = <String>{};

  /// A scheduled ride is a day plus a time. The day starts on today — the ride
  /// people schedule is nearly always one later the same day — so choosing
  /// "Later" only has to ask for the time; the day sits beside it, ready to be
  /// changed for the rarer case.
  DateTime _scheduledDay = DateUtils.dateOnly(DateTime.now());
  TimeOfDay? _scheduledTime;

  /// False means "now" — the passenger wants a ride as soon as someone can come,
  /// and the request carries no scheduled time at all.
  bool _scheduling = false;

  /// The instant the passenger wants to be picked up, once they've named a time.
  DateTime? get _scheduledFor {
    final time = _scheduledTime;
    if (time == null) return null;
    return DateTime(
      _scheduledDay.year,
      _scheduledDay.month,
      _scheduledDay.day,
      time.hour,
      time.minute,
    );
  }

  /// The other members tagged as riding along, in the order they were tagged.
  /// Tagging is optional — you needn't name anyone — but you can't name more
  /// people than the party has room for, or name anyone you're asking to drive.
  final Set<String> _taggedIds = <String>{};

  /// Whether the picker for adding a co-rider is open. It sits behind a "+" so
  /// the section reads as the (usually short) list of people already tagged.
  bool _addingRider = false;

  /// [_partySize] counts the passenger, so the rest of the party is everyone
  /// else — that's how many riders can be tagged.
  int get _taggableCount => _partySize - 1;

  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _optionsFuture = _load();
  }

  @override
  void dispose() {
    _offer.dispose();
    super.dispose();
  }

  Future<_RideOptions> _load() async {
    try {
      final results = await Future.wait([
        widget.api.fetchPlaces(
          groupId: widget.session.groupId,
          token: widget.session.token,
        ),
        widget.api.fetchRoster(
          groupId: widget.session.groupId,
          token: widget.session.token,
        ),
      ]);
      return _RideOptions(
        places: results[0] as Places,
        roster: results[1] as Roster,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 401) widget.onUnauthenticated?.call();
      rethrow;
    }
  }

  void _reload() => setState(() => _optionsFuture = _load());

  /// Switching to "Later" asks for the time and nothing else: the day is already
  /// today. Backing out of the time picker leaves the form in "Later" with the
  /// day control showing, so the other order — day first, then time — works too.
  Future<void> _scheduleLater() async {
    setState(() {
      _scheduling = true;
      _error = null;
    });
    if (_scheduledTime == null) await _chooseTime();
  }

  Future<TimeOfDay?> _pickTimeWithMaterialPicker(
    BuildContext context,
    TimeOfDay initial,
  ) => showTimePicker(context: context, initialTime: initial);

  Future<DateTime?> _pickDayWithMaterialPicker(
    BuildContext context,
    DateTime initial,
  ) {
    // Yesterday can't be scheduled, and the picker asserts if its initial day
    // falls before its first — which the chosen day would, had the form sat open
    // across midnight.
    final today = DateUtils.dateOnly(DateTime.now());
    final seed = initial.isBefore(today) ? today : initial;
    return showDatePicker(
      context: context,
      initialDate: seed,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
    );
  }

  Future<void> _chooseTime() async {
    final pick = widget.pickScheduledTime ?? _pickTimeWithMaterialPicker;
    // Open on an hour out: a scheduled ride is for later, and the server rejects
    // a time that has already passed.
    final initial =
        _scheduledTime ??
        TimeOfDay.fromDateTime(DateTime.now().add(const Duration(hours: 1)));

    final picked = await pick(context, initial);
    if (picked == null || !mounted) return;
    setState(() {
      _scheduledTime = picked;
      _error = _pastScheduleWarning();
    });
  }

  Future<void> _chooseDay() async {
    final pick = widget.pickScheduledDay ?? _pickDayWithMaterialPicker;
    final picked = await pick(context, _scheduledDay);
    if (picked == null || !mounted) return;
    setState(() {
      _scheduledDay = DateUtils.dateOnly(picked);
      _error = _pastScheduleWarning();
    });
  }

  /// A time already gone by on the chosen day is caught as soon as it's chosen,
  /// rather than at submit — the fix (a later time, or another day) is right
  /// there, and picking either clears this.
  String? _pastScheduleWarning() {
    final at = _scheduledFor;
    if (at == null || at.isAfter(DateTime.now())) return null;
    return 'That time has already passed. Pick a later time, or another day.';
  }

  /// Shrinking the party drops the riders it no longer has room for, newest tag
  /// first — the count the passenger just set is what they meant.
  void _setPartySize(int size) {
    setState(() {
      _partySize = size;
      while (_taggedIds.length > _taggableCount) {
        _taggedIds.remove(_taggedIds.last);
      }
      // A party with no room left has nobody to add.
      if (_taggedIds.length >= _taggableCount) _addingRider = false;
      _error = null;
    });
  }

  /// Someone you're asking is a driver, not a passenger, so adding them to the
  /// ping untags them if they were riding along.
  void _addTarget(String memberId) {
    setState(() {
      _targetIds.add(memberId);
      _taggedIds.remove(memberId);
      _error = null;
    });
  }

  void _removeTarget(String memberId) {
    setState(() {
      _targetIds.remove(memberId);
      _error = null;
    });
  }

  void _addRider(String memberId) {
    setState(() {
      _taggedIds.add(memberId);
      _addingRider = false;
      _error = null;
    });
  }

  void _removeRider(String memberId) {
    setState(() {
      _taggedIds.remove(memberId);
      _error = null;
    });
  }

  /// What's missing, if anything — the one message the passenger needs to see.
  String? _validate() {
    if (_pickup == null) return 'Pick where you are.';
    if (_dropoff == null) return 'Pick where you’re going.';
    if (_pickup!.id == _dropoff!.id) {
      return 'Pick two different places.';
    }
    if (_targetIds.isEmpty) return 'Choose someone to ask.';
    if (_scheduling) {
      if (_scheduledTime == null) return 'Pick a time, or switch to Now.';
      final past = _pastScheduleWarning();
      if (past != null) return past;
    }
    return null;
  }

  Future<void> _submit() async {
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await widget.api.createRide(
        groupId: widget.session.groupId,
        token: widget.session.token,
        pickupId: _pickup!.id,
        dropoffId: _dropoff!.id,
        targetIds: _targetIds.toList(),
        partySize: _partySize,
        offer: _offer.text,
        scheduledFor: _scheduling ? _scheduledFor : null,
        partyMemberIds: _taggedIds.toList(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (e.statusCode == 401) widget.onUnauthenticated?.call();
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = "Couldn't reach Goober. Try again.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Get a ride')),
      body: FutureBuilder<_RideOptions>(
        future: _optionsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _RequestError(error: snapshot.error, onRetry: _reload);
          }

          final options = snapshot.data!;
          final places = options.places.places;
          final others = options.roster.othersThan(widget.session.member.id);

          // You can't ask for a ride between places that don't exist, or ask a
          // group of one. Say so plainly instead of showing a dead form.
          if (places.length < 2) {
            return const _CannotRequest(
              emoji: '📍',
              title: 'No places to ride between',
              detail:
                  'Your group needs at least two places on the map before '
                  'anyone can ask for a ride. An admin can add them on the '
                  'Places screen.',
            );
          }
          if (others.isEmpty) {
            return const _CannotRequest(
              emoji: '👋',
              title: "You're the only one here",
              detail:
                  'Once someone else joins the group, you can ask them for a '
                  'ride.',
            );
          }

          return _buildForm(places, others);
        },
      ),
    );
  }

  Widget _buildForm(List<Place> places, List<RosterMember> others) {
    // A rider is someone coming along, so they're neither the passenger (never
    // in `others`) nor anyone being asked to drive.
    final riders = others
        .where((m) => _taggedIds.contains(m.id))
        .toList(growable: false);
    final riderCandidates = others
        .where((m) => !_taggedIds.contains(m.id) && !_targetIds.contains(m.id))
        .toList(growable: false);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        _Label('Where are you?'),
        _PlaceField(
          fieldKey: const Key('pickup-field'),
          hint: 'Pick-up',
          places: places,
          selected: _pickup,
          onChanged: (place) => setState(() {
            _pickup = place;
            _error = null;
          }),
        ),
        const SizedBox(height: 16),

        _Label('Where to?'),
        _PlaceField(
          fieldKey: const Key('dropoff-field'),
          hint: 'Drop-off',
          places: places,
          selected: _dropoff,
          onChanged: (place) => setState(() {
            _dropoff = place;
            _error = null;
          }),
        ),
        const SizedBox(height: 24),

        _Label('How many of you?'),
        Row(
          children: [
            IconButton.outlined(
              key: const Key('party-size-decrement'),
              icon: const Icon(Icons.remove),
              onPressed: _partySize > 1
                  ? () => _setPartySize(_partySize - 1)
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                '$_partySize',
                key: const Key('party-size-value'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            IconButton.outlined(
              key: const Key('party-size-increment'),
              icon: const Icon(Icons.add),
              onPressed: _partySize < maxPartySize
                  ? () => _setPartySize(_partySize + 1)
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 24),

        _Label('When?'),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              key: const Key('timing-now'),
              label: const Text('Now'),
              selected: !_scheduling,
              onSelected: (_) => setState(() {
                _scheduling = false;
                _error = null;
              }),
            ),
            ChoiceChip(
              key: const Key('timing-scheduled'),
              label: const Text('Later'),
              selected: _scheduling,
              onSelected: (_) => _scheduleLater(),
            ),
          ],
        ),
        if (_scheduling) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: const Key('pick-day-button'),
                onPressed: _chooseDay,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.event, size: 18),
                    const SizedBox(width: 8),
                    Text(formatRideDay(_scheduledDay)),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
              OutlinedButton.icon(
                key: const Key('pick-time-button'),
                onPressed: _chooseTime,
                icon: const Icon(Icons.schedule),
                label: Text(
                  _scheduledTime == null
                      ? 'Pick a time'
                      : formatClockTime(_scheduledFor!),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 24),

        // Ask one person, or a few — whoever might be free. Everyone picked is
        // asked; the first who can come takes the ride.
        _Label('Who are you asking?'),
        _MemberPicker(
          key: const Key('target-picker'),
          hint: 'Add someone to ask',
          emptyHint: "You've asked everyone",
          candidates: others
              .where((m) => !_targetIds.contains(m.id))
              .toList(growable: false),
          onPicked: _addTarget,
        ),
        if (_targetIds.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final member in others.where(
                (m) => _targetIds.contains(m.id),
              ))
                InputChip(
                  key: Key('target-chip-${member.id}'),
                  label: Text(member.displayName),
                  onDeleted: () => _removeTarget(member.id),
                ),
            ],
          ),
        ],
        const SizedBox(height: 24),

        _Label('What are you offering? (optional)'),
        TextField(
          key: const Key('offer-field'),
          controller: _offer,
          decoration: const InputDecoration(
            hintText: '🍪 cookies, a favor, or cash',
          ),
          textCapitalization: TextCapitalization.sentences,
        ),
        const SizedBox(height: 24),

        // Tagging is a nicety: the driver mainly needs the headcount above. The
        // people on offer are the ones who could actually be riding — not the
        // passenger, and nobody being asked to drive — and only as many of them
        // as the party size leaves room for.
        _Label("Who's riding with you? (optional)"),
        Text(
          key: const Key('tag-party-hint'),
          _taggableCount == 0
              ? "You said it's just you — raise the party size to add anyone."
              : 'Up to $_taggableCount other'
                    '${_taggableCount == 1 ? '' : 's'}, '
                    'for a party of $_partySize.',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final member in riders)
              InputChip(
                key: Key('rider-chip-${member.id}'),
                label: Text(member.displayName),
                onDeleted: () => _removeRider(member.id),
              ),
            IconButton.outlined(
              key: const Key('add-rider-button'),
              icon: const Icon(Icons.add),
              tooltip: 'Add someone riding with you',
              // Nobody left to add, or no room left in the party: raise the
              // party size, or untag someone.
              onPressed: riderCandidates.isEmpty || _taggedIds.length >= _taggableCount
                  ? null
                  : () => setState(() => _addingRider = true),
            ),
          ],
        ),
        if (_addingRider) ...[
          const SizedBox(height: 8),
          _MemberPicker(
            key: const Key('rider-picker'),
            hint: 'Add someone riding with you',
            emptyHint: 'Nobody left to add',
            candidates: riderCandidates,
            onPicked: _addRider,
          ),
        ],

        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(
            _error!,
            key: const Key('request-ride-error'),
            style: const TextStyle(color: GooberColors.coral),
          ),
        ],

        const SizedBox(height: 24),
        SizedBox(
          height: 56,
          child: FilledButton.icon(
            key: const Key('submit-ride-button'),
            onPressed: _submitting ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: GooberColors.cartTeal,
              textStyle: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            icon: const Icon(Icons.send),
            label: Text(_submitting ? 'Asking…' : 'Ask for a ride'),
          ),
        ),
      ],
    );
  }
}

/// A dropdown over people, name-sorted, that adds whoever is picked.
///
/// The same picker names the people being asked to drive and the people riding
/// along: pick a name, and it becomes a chip beside the field. A dropdown (over
/// a type-ahead) keeps it easy to use for a family of any age, and a group is
/// small enough that the whole list fits in one.
class _MemberPicker extends StatelessWidget {
  const _MemberPicker({
    super.key,
    required this.hint,
    required this.emptyHint,
    required this.candidates,
    required this.onPicked,
  });

  final String hint;

  /// What the field says when there's nobody left to pick — everyone on offer is
  /// already chosen.
  final String emptyHint;

  /// Who can still be picked. Shown sorted by name, so the list reads the same
  /// however the roster came back.
  final List<RosterMember> candidates;
  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) {
    final sorted = [...candidates]
      ..sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );

    return DropdownButtonFormField<String>(
      // The field holds no selection of its own: whoever is picked moves out to
      // a chip and off the list, so the field starts over on the shorter list,
      // ready for the next name.
      key: ValueKey(sorted.map((m) => m.id).join(',')),
      isExpanded: true,
      decoration: InputDecoration(
        hintText: sorted.isEmpty ? emptyHint : hint,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final member in sorted)
          DropdownMenuItem<String>(
            value: member.id,
            child: Text(member.displayName),
          ),
      ],
      onChanged: sorted.isEmpty
          ? null
          : (id) {
              if (id != null) onPicked(id);
            },
    );
  }
}

/// A dropdown over the group's curated places.
class _PlaceField extends StatelessWidget {
  const _PlaceField({
    required this.fieldKey,
    required this.hint,
    required this.places,
    required this.selected,
    required this.onChanged,
  });

  final Key fieldKey;
  final String hint;
  final List<Place> places;
  final Place? selected;
  final ValueChanged<Place?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: fieldKey,
      initialValue: selected?.id,
      isExpanded: true,
      decoration: InputDecoration(
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final place in places)
          DropdownMenuItem<String>(value: place.id, child: Text(place.name)),
      ],
      onChanged: (id) =>
          onChanged(id == null ? null : places.firstWhere((p) => p.id == id)),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// Why a ride can't be asked for yet — a dead end stated kindly, rather than a
/// form that can only fail.
class _CannotRequest extends StatelessWidget {
  const _CannotRequest({
    required this.emoji,
    required this.title,
    required this.detail,
  });

  final String emoji;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 56)),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: GooberColors.ink),
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestError extends StatelessWidget {
  const _RequestError({required this.error, required this.onRetry});

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
