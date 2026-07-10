-- Curated places: the group's named houses and landmarks ("Grandma's", "The
-- Pier", "Ice Cream Shack"), each with coordinates the admin sets so places can
-- later be shown on a map.
--
-- Places are scoped to a group: every row belongs to exactly one group and is
-- only ever read or written in the context of that group. Only a group's admin
-- may create, rename, move, or delete its places; any member may read them.
-- That authorization is enforced in the handlers, not the schema.

CREATE TABLE places (
    id         TEXT PRIMARY KEY NOT NULL,
    group_id   TEXT NOT NULL REFERENCES groups (id),
    name       TEXT NOT NULL,
    -- Coordinates of the dropped pin. Stored as REAL (f64) degrees:
    -- latitude in [-90, 90], longitude in [-180, 180] (validated in the handler).
    lat        REAL NOT NULL,
    lng        REAL NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_places_group ON places (group_id);
