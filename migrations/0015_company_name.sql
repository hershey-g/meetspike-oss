-- Company display names, keyed by registrable email domain ("acme.co.uk").
-- Companies themselves are derived from attendee emails at read time; this
-- table only holds a name the owner chose. Without a row the name comes from
-- the domain ("acme-corp.com" is "Acme Corp"). 0001–0014 stay frozen.
-- Code tolerates this table being absent (migration not yet applied).

CREATE TABLE IF NOT EXISTS company_name (
  domain      TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

-- The owner's own addresses (attendees marked self), read on every response
-- that carries attendees to learn the owner's domains. A small partial index,
-- so that read does not scan every attendee row.
CREATE INDEX IF NOT EXISTS idx_calendar_attendee_self_email ON calendar_attendee (email) WHERE self = 1;
