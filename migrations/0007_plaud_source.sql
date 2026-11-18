-- Plaud phone / [meetspike]-tagged recordings share calendar_event so the
-- existing in-window HR join applies. 0001–0006 stay frozen.
-- Calendar rows keep source_type='calendar'. Plaud rows use source='plaud'
-- and a unique plaud_file_id for idempotent upserts.
-- Do not store transcripts, audio URLs, or secrets on this table.

ALTER TABLE calendar_event ADD COLUMN source_type TEXT NOT NULL DEFAULT 'calendar';
ALTER TABLE calendar_event ADD COLUMN plaud_file_id TEXT;
ALTER TABLE calendar_event ADD COLUMN sync_reason TEXT;
ALTER TABLE calendar_event ADD COLUMN has_transcript INTEGER;
ALTER TABLE calendar_event ADD COLUMN synced_at TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_event_plaud_file_id
  ON calendar_event (plaud_file_id)
  WHERE plaud_file_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_calendar_event_source_type
  ON calendar_event (source_type);
