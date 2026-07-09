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

/// The group activity feed. `rides` is empty in the walking skeleton.
class Feed {
  const Feed({
    required this.groupId,
    required this.groupName,
    required this.rides,
  });

  final String groupId;
  final String groupName;
  final List<dynamic> rides;

  bool get isEmpty => rides.isEmpty;

  factory Feed.fromJson(Map<String, dynamic> json) => Feed(
    groupId: json['group_id'] as String,
    groupName: json['group_name'] as String,
    rides: (json['rides'] as List<dynamic>?) ?? const [],
  );
}
