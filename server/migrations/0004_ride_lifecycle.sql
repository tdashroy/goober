-- The ride lifecycle: who claimed a ride, what everyone pinged said back, and
-- the history of how the ride got where it is.
--
-- A ride walks 'open' -> 'accepted' -> 'arrived' -> 'delivered'. The server owns
-- that walk: every move is checked against the ride's current status and the
-- person making it, so the app can only ever ask for a move, never assert one.

-- Who is driving. NULL until someone accepts; set once, when the first pinged
-- member says "on my way" and claims the ride. That claim is what makes the ride
-- theirs: the rest of the people pinged are off the hook, and only the driver
-- can mark it arrived.
ALTER TABLE rides ADD COLUMN driver_id TEXT REFERENCES members (id);

-- What each pinged member said back — the current answer from each of them, one
-- row per person (answering again replaces the old answer: someone who couldn't
-- come may find a cart after all).
--
-- The answer is one of four, and it is never free text:
--
--   'on_my_way'     coming — this is the accept that claims the ride
--   'cant_right_now' not coming
--   'no_cart'        not coming; `person_id` optionally names who took the cart
--   'someone_else'   not coming, but `person_id` is coming instead
--
-- `person_id` is a **member**, not a name typed in a box, precisely so the app
-- can act on it: the passenger taps the person named and pings them, which is
-- how a dead end ("Susan took my cart") turns into the next ride in one tap.
CREATE TABLE ride_responses (
    ride_id    TEXT NOT NULL REFERENCES rides (id),
    -- The pinged member answering. Must be one of the ride's `ride_targets`,
    -- which the handler enforces — SQL can't express "a row in that set".
    member_id  TEXT NOT NULL REFERENCES members (id),
    response   TEXT NOT NULL,
    -- The person the answer points at: the lead who took the cart, or the driver
    -- coming instead. NULL for the answers that name nobody.
    person_id  TEXT REFERENCES members (id),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (ride_id, member_id)
);

-- The audit trail: every step a ride took, in order, and who took it. The rides
-- table holds only where a ride *is*; this holds how it got there — the request,
-- each answer to the ping, the claim, the arrival, the hand-off at the door.
--
-- Append-only. Nothing reads it to decide anything (the ride's own status does
-- that); it exists so the history of a ride survives the ride, which is what
-- points, disputes and "wait, who drove me?" all end up needing.
CREATE TABLE ride_events (
    id         TEXT PRIMARY KEY NOT NULL,
    ride_id    TEXT NOT NULL REFERENCES rides (id),
    -- Who did it: the passenger requesting, a pinged member answering, the
    -- driver arriving, either of them closing the ride out.
    actor_id   TEXT NOT NULL REFERENCES members (id),
    -- 'requested', or any of the four answers above, or 'arrived' / 'delivered'.
    kind       TEXT NOT NULL,
    -- The person the step named, if it named one — same leads and delegates as
    -- `ride_responses.person_id`. NULL for the steps that name nobody.
    person_id  TEXT REFERENCES members (id),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- The trail is always read one ride at a time, oldest step first.
CREATE INDEX idx_ride_events_ride ON ride_events (ride_id, created_at);
