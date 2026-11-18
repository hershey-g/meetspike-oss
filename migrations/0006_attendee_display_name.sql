-- Google Calendar displayName on the attendee index, plus a tighter
-- raw_object lookup for heartrate archives (person history reads).
-- 0001–0005 stay frozen.

ALTER TABLE calendar_attendee ADD COLUMN display_name TEXT;

CREATE INDEX IF NOT EXISTS idx_raw_object_source_endpoint_day
  ON raw_object (source, endpoint, day);
