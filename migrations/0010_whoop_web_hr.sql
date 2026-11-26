-- Per-meeting heart rate and per-day Stress Monitor from WHOOP's web app API
-- (feature flag WHOOP_WEB_HR). 0001–0009 stay frozen.
-- Code tolerates these tables being absent (migration not yet applied): the
-- meeting view then says "No heart rate for this meeting".
-- Never store tokens, passwords or raw WHOOP responses here.

-- One row per calendar meeting. The window is meeting start-10 min to
-- end+10 min; if the meeting moves, the stored window no longer matches and
-- the row is fetched again.
-- status: 'ok' (samples_json has data), 'empty' (WHOOP had no samples),
--         'error' (the call failed; error_text says why, without secrets).
-- samples_json: [[unix_ms, bpm], ...] at 1-minute steps.
CREATE TABLE IF NOT EXISTS whoop_web_hr (
  event_id          TEXT PRIMARY KEY,
  window_start_utc  TEXT NOT NULL,
  window_end_utc    TEXT NOT NULL,
  status            TEXT NOT NULL,
  sample_count      INTEGER NOT NULL DEFAULT 0,
  samples_json      TEXT,
  error_text        TEXT,
  fetched_at        TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_whoop_web_hr_window
  ON whoop_web_hr (window_start_utc);

-- One row per local day: the Stress Monitor line (0–3), sliced per meeting
-- at read time. points_json: [[unix_ms, level], ...].
CREATE TABLE IF NOT EXISTS whoop_web_stress_day (
  day            TEXT PRIMARY KEY,
  status         TEXT NOT NULL,
  point_count    INTEGER NOT NULL DEFAULT 0,
  points_json    TEXT,
  current_level  REAL,
  peak_level     REAL,
  min_level      REAL,
  error_text     TEXT,
  fetched_at     TEXT NOT NULL
);
