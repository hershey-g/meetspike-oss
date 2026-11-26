-- Each Meetspike installation has one owner. Separate sources can report
-- different values at the same timestamp, so keep both readings.
CREATE TABLE whoop_web_hr_raw (
  user_id     TEXT NOT NULL,
  source      TEXT NOT NULL CHECK (source IN ('ble', 'codebox')),
  time_ms     INTEGER NOT NULL,
  bpm         INTEGER NOT NULL,
  received_at TEXT NOT NULL,
  PRIMARY KEY (user_id, time_ms, source)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_calendar_event_active_start
  ON calendar_event (start_utc) WHERE deleted_at IS NULL;
