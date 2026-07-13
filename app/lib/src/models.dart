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

/// A ride as the feed shows it: who asked, who they pinged, the route, how many
/// are riding, what's on offer, and when it's wanted for.
class Ride {
  const Ride({
    required this.id,
    required this.groupId,
    required this.status,
    required this.passenger,
    required this.targets,
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

  /// `open` today; a driver accepting / arriving / delivering comes later.
  final String status;
  final MemberRef passenger;

  /// Everyone who was pinged — one person, or a few. Never empty: a ride with
  /// nobody asked would be a broadcast ("anyone?"), which isn't built yet.
  final List<MemberRef> targets;
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

  factory Ride.fromJson(Map<String, dynamic> json) => Ride(
    id: json['id'] as String,
    groupId: json['group_id'] as String,
    status: json['status'] as String,
    passenger: MemberRef.fromJson(json['passenger'] as Map<String, dynamic>),
    targets: ((json['targets'] as List<dynamic>?) ?? const [])
        .map((m) => MemberRef.fromJson(m as Map<String, dynamic>))
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
}
