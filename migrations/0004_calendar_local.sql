-- Local wall-clock copies of start/end for API responses and DST-safe inspection.
-- Computed from start_utc/end_utc + America/New_York (or event offset) at ingest.

ALTER TABLE calendar_event ADD COLUMN start_local TEXT;
ALTER TABLE calendar_event ADD COLUMN end_local TEXT;
