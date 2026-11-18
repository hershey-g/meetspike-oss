-- Work calendar events (Google Calendar + sandbox fixtures).
-- Join key: `day` is local work day D. Oura sleep/readiness for that day
-- live on morning D+1 (see src/sources/calendar/join.ts).
-- start_local / end_local added in 0004 so this file stays frozen if already applied.

CREATE TABLE IF NOT EXISTS calendar_event (
  id              TEXT NOT NULL,
  source          TEXT NOT NULL,
  day             TEXT NOT NULL,
  start_utc       TEXT NOT NULL,
  end_utc         TEXT NOT NULL,
  tz_offset_min   INTEGER NOT NULL,
  duration_s      INTEGER NOT NULL,
  title           TEXT,
  kind            TEXT NOT NULL,
  client_key      TEXT,
  project_key     TEXT,
  attendee_count  INTEGER,
  after_hours     INTEGER NOT NULL DEFAULT 0,
  location        TEXT,
  raw_id          INTEGER REFERENCES raw_object(id),
  deleted_at      TEXT,
  updated_at      TEXT NOT NULL,
  PRIMARY KEY (id, source)
);

CREATE INDEX IF NOT EXISTS idx_calendar_event_day ON calendar_event (day, start_utc);
CREATE INDEX IF NOT EXISTS idx_calendar_event_kind ON calendar_event (kind);
