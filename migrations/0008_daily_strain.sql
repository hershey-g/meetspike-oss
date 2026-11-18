-- Whole-day exertion for wearables that report it (WHOOP day strain, 0–21,
-- with the day's average and max heart rate). 0001–0007 stay frozen.
-- A separate table on purpose: Oura never reads or writes it, so an Oura
-- install keeps working whether or not this migration has been applied.

CREATE TABLE IF NOT EXISTS daily_strain (
  day         TEXT NOT NULL,
  source      TEXT NOT NULL,
  source_day  TEXT,
  strain      REAL,
  avg_hr      INTEGER,
  max_hr      INTEGER,
  kilojoule   REAL,
  raw_id      INTEGER REFERENCES raw_object(id),
  deleted_at  TEXT,
  updated_at  TEXT NOT NULL,
  PRIMARY KEY (day, source)
);
