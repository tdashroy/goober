-- Goober walking skeleton schema.
--
-- Scope is deliberately just Group + Member — the two tables the join/auth spine
-- needs. Places, Rides, Messages, IOUs come later and are NOT
-- created here on purpose.
--
-- Identity model: the phone number is the durable identity key; the
-- display name is a mutable label on top of it. Re-joining with the same phone
-- re-attaches the same member row rather than creating a duplicate — enforced by
-- the UNIQUE (group_id, phone) constraint.

CREATE TABLE groups (
    id         TEXT PRIMARY KEY NOT NULL,
    name       TEXT NOT NULL,
    -- Member id of the admin (whoever creates a group is its admin).
    -- Nullable only to break the chicken-and-egg with members(group_id); it is
    -- set within the same create-group transaction and never left null in practice.
    created_by TEXT REFERENCES members (id),
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE members (
    id           TEXT PRIMARY KEY NOT NULL,
    group_id     TEXT NOT NULL REFERENCES groups (id),
    -- Durable identity key. Unique within a group so a re-join re-attaches.
    phone        TEXT NOT NULL,
    -- Mutable label; updated on re-join if the person typed a new name.
    display_name TEXT NOT NULL,
    -- Random bearer token issued on join; sent on every authenticated request.
    token        TEXT NOT NULL UNIQUE,
    is_admin     INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (group_id, phone)
);

CREATE INDEX idx_members_group ON members (group_id);
