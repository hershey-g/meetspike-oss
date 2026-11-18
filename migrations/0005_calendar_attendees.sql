-- Attendee emails for person-level meeting history.
-- calendar_event previously stored only attendee_count. Emails already exist
-- on the Google/sandbox archive in R2; this projects them for reads.
-- 0001–0004 stay frozen.

ALTER TABLE calendar_event ADD COLUMN attendees_json TEXT;

CREATE TABLE IF NOT EXISTS calendar_attendee (
  event_id TEXT NOT NULL,
  source   TEXT NOT NULL,
  email    TEXT NOT NULL,
  self     INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (event_id, source, email)
);

CREATE INDEX IF NOT EXISTS idx_calendar_attendee_email ON calendar_attendee (email, self);
