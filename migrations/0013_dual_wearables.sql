-- Attribution for each evaluated meeting window. The device-specific readings
-- stay in the WHOOP cache and the Oura R2 archive.
CREATE TABLE meeting_hr_source (
  event_id   TEXT NOT NULL,
  start_utc  TEXT NOT NULL,
  end_utc    TEXT NOT NULL,
  source     TEXT NOT NULL CHECK (source IN ('WHOOP', 'Oura', 'WHOOP + Oura')),
  PRIMARY KEY (event_id, start_utc, end_utc)
);

-- History jobs use a dedicated trigger per Workflow instance. Completed
-- window rows remain available as checkpoints if the instance is restarted.
CREATE INDEX idx_sync_log_history ON sync_log (trigger, source, status, endpoint, window_start, window_end);

-- Re-run a wearable projection if a pull stopped between archiving its raw
-- revision and projecting it. Existing raw pointers keep their prior state.
ALTER TABLE raw_object ADD COLUMN projection_pending INTEGER NOT NULL DEFAULT 0;
