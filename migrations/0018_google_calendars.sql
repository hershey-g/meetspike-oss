-- More than one Google account, and a choice of calendars in each.
-- 0001–0017 stay frozen.
--
-- Tokens stay in KV, one key per account: google:tokens:<email>. The old
-- single key google:tokens is moved there by the Worker on first run (it has
-- to ask Google which address the token belongs to, which SQL cannot).

-- One row per connected Google account. Every address here is the owner.
CREATE TABLE IF NOT EXISTS google_account (
  email         TEXT PRIMARY KEY,
  connected_at  TEXT NOT NULL,
  last_sync_at  TEXT,
  last_error    TEXT,
  updated_at    TEXT NOT NULL
);

-- Calendars in each account (Google calendarList). `selected` decides which
-- ones count as meetings. New calendars start unselected except the primary,
-- so a deploy alone changes nothing. Each calendar keeps its own sync token.
CREATE TABLE IF NOT EXISTS google_calendar (
  account_email  TEXT NOT NULL,
  calendar_id    TEXT NOT NULL,
  summary        TEXT,
  is_primary     INTEGER NOT NULL DEFAULT 0,
  access_role    TEXT,
  color          TEXT,
  selected       INTEGER NOT NULL DEFAULT 0,
  sync_token     TEXT,
  last_sync_at   TEXT,
  last_error     TEXT,
  updated_at     TEXT NOT NULL,
  PRIMARY KEY (account_email, calendar_id)
);

-- Where each stored Google meeting was seen. calendar_event keeps one row per
-- meeting (event_id). The same meeting on two calendars or two accounts
-- (same Google event id, or same iCalUID and start) has two origin rows that
-- point at one calendar_event row, so heart rate, people and companies count
-- it once. A meeting stays visible while at least one of its origins is on a
-- selected calendar. A cancelled occurrence drops its origin row.
CREATE TABLE IF NOT EXISTS calendar_event_origin (
  account_email    TEXT NOT NULL,
  calendar_id      TEXT NOT NULL,
  google_event_id  TEXT NOT NULL,
  event_id         TEXT NOT NULL,
  ical_uid         TEXT,
  start_utc        TEXT,
  updated_at       TEXT NOT NULL,
  PRIMARY KEY (account_email, calendar_id, google_event_id)
);

CREATE INDEX IF NOT EXISTS idx_calendar_event_origin_event ON calendar_event_origin (event_id);
CREATE INDEX IF NOT EXISTS idx_calendar_event_origin_ical ON calendar_event_origin (ical_uid, start_utc);
CREATE INDEX IF NOT EXISTS idx_calendar_event_origin_gid ON calendar_event_origin (google_event_id);

-- Meetings already stored came from the one connected account's primary
-- calendar. Record that with an empty account; the Worker fills in the
-- address when it moves the old token (src/sources/calendar/accounts.ts).
INSERT OR IGNORE INTO calendar_event_origin
  (account_email, calendar_id, google_event_id, event_id, ical_uid, start_utc, updated_at)
SELECT '', '', id, id, NULL, start_utc, updated_at
FROM calendar_event
WHERE source = 'google' AND deleted_at IS NULL;
