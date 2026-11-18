-- Versioned raw archive index. Bodies live in R2; this table is the pointer.
-- UNIQUE includes content_hash so Oura revisions append; never delete objects.

CREATE TABLE raw_object (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  source        TEXT NOT NULL,
  endpoint      TEXT NOT NULL,
  document_id   TEXT NOT NULL,
  day           TEXT,
  r2_key        TEXT NOT NULL,
  content_hash  TEXT NOT NULL,
  fetched_at    TEXT NOT NULL,
  UNIQUE (source, endpoint, document_id, content_hash)
);

CREATE TABLE user_profile (
  id             TEXT PRIMARY KEY,
  time_zone      TEXT NOT NULL DEFAULT 'America/New_York',
  oura_user_id   TEXT,
  personal_json  TEXT,
  updated_at     TEXT NOT NULL
);

CREATE TABLE daily_sleep (
  day               TEXT NOT NULL,
  source            TEXT NOT NULL,
  source_day        TEXT,
  score             INTEGER,
  total_sleep_s     INTEGER,
  time_in_bed_s     INTEGER,
  efficiency        INTEGER,
  latency_s         INTEGER,
  deep_s            INTEGER,
  rem_s             INTEGER,
  light_s           INTEGER,
  awake_s           INTEGER,
  avg_hrv           REAL,
  avg_hr            REAL,
  lowest_hr         REAL,
  respiratory_rate  REAL,
  contributors_json TEXT,
  raw_id            INTEGER REFERENCES raw_object(id),
  deleted_at        TEXT,
  updated_at        TEXT NOT NULL,
  PRIMARY KEY (day, source)
);

CREATE TABLE daily_readiness (
  day                    TEXT NOT NULL,
  source                 TEXT NOT NULL,
  source_day             TEXT,
  score                  INTEGER,
  temperature_deviation  REAL,
  contributors_json      TEXT,
  raw_id                 INTEGER REFERENCES raw_object(id),
  deleted_at             TEXT,
  updated_at             TEXT NOT NULL,
  PRIMARY KEY (day, source)
);

CREATE TABLE daily_activity (
  day          TEXT NOT NULL,
  source       TEXT NOT NULL,
  source_day   TEXT,
  score        INTEGER,
  steps        INTEGER,
  active_cal   INTEGER,
  total_cal    INTEGER,
  met_minutes  REAL,
  class_5_min  TEXT,
  raw_id       INTEGER REFERENCES raw_object(id),
  deleted_at   TEXT,
  updated_at   TEXT NOT NULL,
  PRIMARY KEY (day, source)
);

CREATE TABLE daily_stress (
  day             TEXT NOT NULL,
  source          TEXT NOT NULL,
  source_day      TEXT,
  stress_high_s   INTEGER,
  recovery_high_s INTEGER,
  day_summary     TEXT,
  raw_id          INTEGER REFERENCES raw_object(id),
  deleted_at      TEXT,
  updated_at      TEXT NOT NULL,
  PRIMARY KEY (day, source)
);

CREATE TABLE sleep_periods (
  id                TEXT NOT NULL,
  source            TEXT NOT NULL,
  day               TEXT NOT NULL,
  source_day        TEXT,
  start_utc         TEXT NOT NULL,
  end_utc           TEXT NOT NULL,
  tz_offset_min     INTEGER NOT NULL,
  time_zone         TEXT,
  period_type       TEXT,
  is_nap            INTEGER NOT NULL DEFAULT 0,
  total_sleep_s     INTEGER,
  deep_s            INTEGER,
  rem_s             INTEGER,
  light_s           INTEGER,
  awake_s           INTEGER,
  efficiency        INTEGER,
  avg_hrv           REAL,
  lowest_hr         REAL,
  respiratory_rate  REAL,
  raw_id            INTEGER REFERENCES raw_object(id),
  deleted_at        TEXT,
  updated_at        TEXT NOT NULL,
  PRIMARY KEY (id, source)
);

CREATE TABLE workouts (
  id          TEXT NOT NULL,
  source      TEXT NOT NULL,
  day         TEXT NOT NULL,
  source_day  TEXT,
  start_utc   TEXT NOT NULL,
  end_utc     TEXT NOT NULL,
  activity    TEXT,
  intensity   TEXT,
  strain      REAL,
  calories    INTEGER,
  avg_hr      INTEGER,
  max_hr      INTEGER,
  raw_id      INTEGER REFERENCES raw_object(id),
  deleted_at  TEXT,
  updated_at  TEXT NOT NULL,
  PRIMARY KEY (id, source)
);

CREATE TABLE sessions (
  id          TEXT NOT NULL,
  source      TEXT NOT NULL,
  start_utc   TEXT NOT NULL,
  end_utc     TEXT NOT NULL,
  type        TEXT,
  mood        TEXT,
  raw_id      INTEGER REFERENCES raw_object(id),
  deleted_at  TEXT,
  updated_at  TEXT NOT NULL,
  PRIMARY KEY (id, source)
);

CREATE TABLE tags (
  id            TEXT NOT NULL,
  source        TEXT NOT NULL,
  day           TEXT NOT NULL,
  tag_code      TEXT,
  comment       TEXT,
  answered_yes  INTEGER,
  raw_id        INTEGER REFERENCES raw_object(id),
  deleted_at    TEXT,
  updated_at    TEXT NOT NULL,
  PRIMARY KEY (id, source)
);

-- Heart-rate time series is R2-only in P1. Do not add hr_samples here.

CREATE TABLE sync_log (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  trigger       TEXT NOT NULL,
  source        TEXT NOT NULL,
  endpoint      TEXT,
  window_start  TEXT,
  window_end    TEXT,
  status        TEXT NOT NULL,
  rows_written  INTEGER DEFAULT 0,
  rows_skipped  INTEGER DEFAULT 0,
  error_text    TEXT,
  event_id      TEXT,
  created_at    TEXT NOT NULL
);

CREATE TABLE webhook_subscription (
  id              TEXT PRIMARY KEY,
  data_type       TEXT NOT NULL,
  event_type      TEXT NOT NULL,
  callback_url    TEXT NOT NULL,
  expiration_time TEXT,
  updated_at      TEXT NOT NULL
);
