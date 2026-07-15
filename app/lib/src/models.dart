// Plain data models mirroring the server's JSON shapes (see server/src/models.rs).

/// A member of a group. Phone is the durable identity key; [displayName] is a
/// mutable label on top of it.
class Member {
  const Member({
    required this.id,
    required this.groupId,
    required this.displayName,
    required this.phone,
    required this.isAdmin,
  });

  final String id;
  final String groupId;
  final String displayName;
  final String phone;
  final bool isAdmin;

  factory Member.fromJson(Map<String, dynamic> json) => Member(
    id: json['id'] as String,
    groupId: json['group_id'] as String,
    displayName: json['display_name'] as String,
    phone: json['phone'] as String,
    isAdmin: json['is_admin'] as bool,
  );
}

/// Everything the app needs to persist after a successful create/join: the
/// bearer [token] plus which group the member is in.
class Session {
  const Session({
    required this.token,
    required this.groupId,
    required this.groupName,
    required this.member,
  });

  final String token;
  final String groupId;
  final String groupName;
  final Member member;

  factory Session.fromJson(Map<String, dynamic> json) => Session(
    token: json['token'] as String,
    groupId: json['group_id'] as String,
    groupName: json['group_name'] as String,
    member: Member.fromJson(json['member'] as Map<String, dynamic>),
  );
}

/// A curated place: a named house or landmark with map coordinates. Only a
/// group's admin can create/rename/delete places; any member can view them.
class Place {
  const Place({
    required this.id,
    required this.groupId,
    required this.name,
    required this.lat,
    required this.lng,
  });

  final String id;
  final String groupId;
  final String name;
  final double lat;
  final double lng;

  factory Place.fromJson(Map<String, dynamic> json) => Place(
    id: json['id'] as String,
    groupId: json['group_id'] as String,
    name: json['name'] as String,
    lat: (json['lat'] as num).toDouble(),
    lng: (json['lng'] as num).toDouble(),
  );
}

/// The group's curated places. The server returns this on read and echoes it
/// back after every mutation so the client refreshes from one response.
class Places {
  const Places({required this.groupId, required this.places});

  final String groupId;
  final List<Place> places;

  bool get isEmpty => places.isEmpty;

  factory Places.fromJson(Map<String, dynamic> json) => Places(
    groupId: json['group_id'] as String,
    places: ((json['places'] as List<dynamic>?) ?? const [])
        .map((p) => Place.fromJson(p as Map<String, dynamic>))
        .toList(),
  );
}

/// One entry in the group roster. The roster is a group-visible surface, so —
/// like [MemberRef] on the feed — it carries no phone numbers; only your own
/// [Member] record does.
class RosterMember {
  const RosterMember({
    required this.id,
    required this.displayName,
    required this.isAdmin,
  });

  final String id;
  final String displayName;
  final bool isAdmin;

  factory RosterMember.fromJson(Map<String, dynamic> json) => RosterMember(
    id: json['id'] as String,
    displayName: json['display_name'] as String,
    isAdmin: json['is_admin'] as bool,
  );
}

/// The group roster: everyone you can ping for a ride.
class Roster {
  const Roster({required this.groupId, required this.members});

  final String groupId;
  final List<RosterMember> members;

  factory Roster.fromJson(Map<String, dynamic> json) => Roster(
    groupId: json['group_id'] as String,
    members: ((json['members'] as List<dynamic>?) ?? const [])
        .map((m) => RosterMember.fromJson(m as Map<String, dynamic>))
        .toList(),
  );

  /// Everyone except [memberId] — you can't ping yourself for a ride.
  List<RosterMember> othersThan(String memberId) =>
      members.where((m) => m.id != memberId).toList();
}

/// A person as they appear inside a ride — just a name. The feed is a public
/// board, so it carries no phone numbers.
class MemberRef {
  const MemberRef({required this.id, required this.displayName});

  final String id;
  final String displayName;

  factory MemberRef.fromJson(Map<String, dynamic> json) => MemberRef(
    id: json['id'] as String,
    displayName: json['display_name'] as String,
  );
}

/// Where a ride has got to. The server owns the walk from one to the next; the
/// app only ever reads these, and asks for the moves in [RideAction].
class RideStatus {
  /// Nobody has claimed it: still on offer to everyone pinged.
  static const open = 'open';

  /// Claimed — the driver is on the way.
  static const accepted = 'accepted';

  /// The driver is at the pickup.
  static const arrived = 'arrived';

  /// Done, and closed.
  static const delivered = 'delivered';
}

/// Every move a ride can be asked to make.
///
/// The first four are the menu a **pinged member** picks from — deliberately not
/// a yes/no, because the three "no"s each carry something the passenger can use.
/// The server decides whether a move is legal, from the ride's status and from
/// who is asking; the app only asks.
enum RideAction {
  /// Accept — and thereby claim the ride. First one there wins.
  onMyWay('on_my_way'),

  /// "Can't right now."
  cantRightNow('cant_right_now'),

  /// "I don't have a cart" — optionally naming who took it.
  noCart('no_cart'),

  /// "Someone else will come" — naming who's actually driving. It doesn't claim
  /// the ride: that person hasn't been asked yet, so the passenger taps them and
  /// asks.
  someoneElse('someone_else'),

  /// The driver is at the pickup.
  arrived('arrived'),

  /// Either the driver or the passenger closes the ride out.
  delivered('delivered');

  const RideAction(this.wire);

  /// How the server spells it.
  final String wire;

  /// The action a wire spelling names, or null for one this build doesn't
  /// know — a newer server may have grown answers this app hasn't heard of.
  static RideAction? fromWire(String raw) {
    for (final a in RideAction.values) {
      if (a.wire == raw) return a;
    }
    return null;
  }
}

/// What one pinged member said back.
class RideResponse {
  const RideResponse({
    required this.member,
    required this.response,
    required this.person,
  });

  /// The pinged member who answered.
  final MemberRef member;

  /// Which of the four they picked.
  final RideAction response;

  /// Who they pointed at, if anyone: the person who took their cart, or the
  /// person coming instead. Tapping them is how the passenger asks *them* for a
  /// ride, which is why a lead is a person and not a sentence.
  final MemberRef? person;

  /// One answer off the wire, or null when its kind is one this build doesn't
  /// know — that answer drops off the list rather than failing the whole feed.
  static RideResponse? fromJson(Map<String, dynamic> json) {
    final response = RideAction.fromWire(json['response'] as String);
    if (response == null) return null;
    return RideResponse(
      member: MemberRef.fromJson(json['member'] as Map<String, dynamic>),
      response: response,
      person: json['person'] == null
          ? null
          : MemberRef.fromJson(json['person'] as Map<String, dynamic>),
    );
  }
}

/// A ride as the feed shows it: who asked, who they pinged, what those people
/// said back, who's driving, the route, how many are riding, what's on offer,
/// and when it's wanted for.
class Ride {
  const Ride({
    required this.id,
    required this.groupId,
    required this.status,
    required this.passenger,
    required this.driver,
    required this.targets,
    required this.responses,
    required this.pickup,
    required this.dropoff,
    required this.partySize,
    required this.party,
    required this.offer,
    required this.scheduledFor,
    required this.createdAt,
  });

  final String id;
  final String groupId;

  /// One of [RideStatus]: `open`, `accepted`, `arrived`, `delivered`.
  final String status;
  final MemberRef passenger;

  /// Who claimed the ride and is driving it. Null until someone accepts.
  final MemberRef? driver;

  /// Everyone who was pinged — one person, or a few. Never empty: a ride with
  /// nobody asked would be a broadcast ("anyone?"), which isn't built yet.
  final List<MemberRef> targets;

  /// What the people pinged have said back so far. Empty until someone answers.
  final List<RideResponse> responses;
  final Place pickup;
  final Place dropoff;

  /// How many are riding, including the passenger. At least 1 ("just me").
  final int partySize;

  /// The other riders the passenger tagged, if any. Tagging is optional, so this
  /// may be shorter than [partySize].
  final List<MemberRef> party;

  /// Free-text thank-you — cookies, a favor, or cash. Null when none was made.
  final String? offer;

  /// Null means "now"; otherwise the time the ride is wanted for.
  final DateTime? scheduledFor;
  final DateTime createdAt;

  /// A scheduled ride is one wanted at a set time rather than right now.
  bool get isScheduled => scheduledFor != null;

  /// Still going begging: nobody has claimed it, so everyone pinged can answer.
  bool get isOpen => status == RideStatus.open;

  /// Whether [memberId] is one of the people asked to drive.
  bool isTarget(String memberId) => targets.any((m) => m.id == memberId);

  /// Whether [memberId] claimed the ride and is driving it.
  bool isDriver(String memberId) => driver?.id == memberId;

  /// What [memberId] has already said back, if they were asked and have.
  RideResponse? responseFrom(String memberId) {
    for (final r in responses) {
      if (r.member.id == memberId) return r;
    }
    return null;
  }

  /// Whether [memberId] still has the four-option menu in front of them: they
  /// were asked, and the ride is still there to be taken. Answering again is
  /// allowed — someone who couldn't come may turn up a cart a minute later.
  bool canAnswer(String memberId) => isOpen && isTarget(memberId);

  /// Whether [memberId] can mark the cart as out front — the driver, once
  /// they've claimed it and before they've got there.
  bool canMarkArrived(String memberId) =>
      status == RideStatus.accepted && isDriver(memberId);

  /// Whether [memberId] can close the ride out. The hand-off happens in person,
  /// so either end of it can say so.
  bool canMarkDelivered(String memberId) =>
      status == RideStatus.arrived &&
      (isDriver(memberId) || passenger.id == memberId);

  factory Ride.fromJson(Map<String, dynamic> json) => Ride(
    id: json['id'] as String,
    groupId: json['group_id'] as String,
    status: json['status'] as String,
    passenger: MemberRef.fromJson(json['passenger'] as Map<String, dynamic>),
    driver: json['driver'] == null
        ? null
        : MemberRef.fromJson(json['driver'] as Map<String, dynamic>),
    targets: ((json['targets'] as List<dynamic>?) ?? const [])
        .map((m) => MemberRef.fromJson(m as Map<String, dynamic>))
        .toList(),
    responses: ((json['responses'] as List<dynamic>?) ?? const [])
        .map((r) => RideResponse.fromJson(r as Map<String, dynamic>))
        .whereType<RideResponse>()
        .toList(),
    pickup: Place.fromJson(json['pickup'] as Map<String, dynamic>),
    dropoff: Place.fromJson(json['dropoff'] as Map<String, dynamic>),
    partySize: (json['party_size'] as num).toInt(),
    party: ((json['party'] as List<dynamic>?) ?? const [])
        .map((m) => MemberRef.fromJson(m as Map<String, dynamic>))
        .toList(),
    offer: json['offer'] as String?,
    // The server sends UTC instants; show them in the rider's local time.
    scheduledFor: _parseTime(json['scheduled_for'] as String?)?.toLocal(),
    createdAt:
        _parseTime(json['created_at'] as String?)?.toLocal() ?? DateTime.now(),
  );
}

DateTime? _parseTime(String? raw) =>
    (raw == null || raw.isEmpty) ? null : DateTime.parse(raw);

/// The group activity feed: every ride in the group, newest first. Shared by the
/// whole group — everyone sees the same board.
class Feed {
  const Feed({
    required this.groupId,
    required this.groupName,
    required this.rides,
  });

  final String groupId;
  final String groupName;
  final List<Ride> rides;

  bool get isEmpty => rides.isEmpty;

  factory Feed.fromJson(Map<String, dynamic> json) => Feed(
    groupId: json['group_id'] as String,
    groupName: json['group_name'] as String,
    rides: ((json['rides'] as List<dynamic>?) ?? const [])
        .map((r) => Ride.fromJson(r as Map<String, dynamic>))
        .toList(),
  );

  /// A copy of this feed with [ride] merged in: it replaces the ride of the same
  /// id if the board already has it, or is inserted if it's new. This is how a
  /// live delta is applied without re-fetching the whole board.
  ///
  /// The result is kept newest-first, the same order the server returns — by
  /// creation time, then id as a stable tiebreaker — so a live update lands in
  /// the same place a refetch would have put it. A ride from another group is
  /// ignored; the stream is group-scoped, but this keeps the merge honest.
  Feed withRide(Ride ride) {
    if (ride.groupId != groupId) return this;
    final merged =
        [
          for (final r in rides)
            if (r.id != ride.id) r,
          ride,
        ]..sort((a, b) {
          final byTime = b.createdAt.compareTo(a.createdAt);
          return byTime != 0 ? byTime : b.id.compareTo(a.id);
        });
    return Feed(groupId: groupId, groupName: groupName, rides: merged);
  }
}
