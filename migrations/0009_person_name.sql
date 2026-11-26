-- Resolved attendee names, cached per email. 0001–0008 stay frozen.
-- source: 'calendar' = a Google displayName seen on any stored meeting;
--         'plaud'    = a Plaud speaker name that mapped cleanly to the email.
-- A calendar name always replaces a plaud one, never the other way round.
-- Code tolerates this table being absent (migration not yet applied).

CREATE TABLE IF NOT EXISTS person_name (
  email       TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  source      TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
