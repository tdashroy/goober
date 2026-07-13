-- Ride requests: a passenger asks to be driven from one curated place to
-- another.
--
-- A request is scoped to a group, like everything else: the passenger, the
-- people pinged, the pickup/dropoff places and any tagged riders all belong to
-- the same group as the ride (enforced in the handler, which resolves each id
-- within the caller's group before inserting).
--
-- Times are stored as ISO-8601 UTC strings ("2027-07-04T18:30:00Z") so they sort
-- lexicographically, compare against SQLite's date functions, and parse directly
-- in the client. `scheduled_for` NULL means "now" — the passenger wants the ride
-- as soon as someone can come.

CREATE TABLE rides (
    id              TEXT PRIMARY KEY NOT NULL,
    group_id        TEXT NOT NULL REFERENCES groups (id),
    -- The member asking for the ride.
    passenger_id    TEXT NOT NULL REFERENCES members (id),
    pickup_id       TEXT NOT NULL REFERENCES places (id),
    dropoff_id      TEXT NOT NULL REFERENCES places (id),
    -- How many people are riding, including the passenger. An exact count of at
    -- least 1 ("just me"); the upper bound is enforced in the handler so the cap
    -- can change without a migration.
    party_size      INTEGER NOT NULL DEFAULT 1 CHECK (party_size >= 1),
    -- Free-text thank-you: cookies, a favor, or cash. Optional by design — this
    -- is barter, not payments. NULL means no offer.
    offer           TEXT,
    -- NULL = "now"; otherwise the future time the ride is wanted for.
    scheduled_for   TEXT,
    -- Ride lifecycle. A new request starts 'open'; the later states (a driver
    -- accepting, arriving, delivering) land with the code that drives them.
    status          TEXT NOT NULL DEFAULT 'open',
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- The feed reads a group's rides newest-first, so index the group.
CREATE INDEX idx_rides_group ON rides (group_id);

-- Who was pinged: the members the passenger asked to come and get them. A ping
-- names a set — one person, or a few — which is the middle ground between
-- asking one driver and broadcasting to the whole group. Everyone in the set is
-- asked; when the accept flow lands, the first of them to say yes takes the
-- ride and the rest are off the hook.
--
-- At least one member per ride is required by the handler rather than the
-- schema, since SQL can't express "this row must have a child".
CREATE TABLE ride_targets (
    ride_id   TEXT NOT NULL REFERENCES rides (id),
    member_id TEXT NOT NULL REFERENCES members (id),
    PRIMARY KEY (ride_id, member_id)
);

-- Who is riding along: the passenger may optionally tag the other members in
-- their party. This is a tag list, not a headcount — `rides.party_size` is the
-- number that matters to a driver sizing up a cart, and the tag list may be
-- shorter (nobody has to tag anyone).
CREATE TABLE ride_party_members (
    ride_id   TEXT NOT NULL REFERENCES rides (id),
    member_id TEXT NOT NULL REFERENCES members (id),
    PRIMARY KEY (ride_id, member_id)
);
