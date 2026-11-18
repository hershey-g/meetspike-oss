CREATE INDEX idx_sleep_periods_start ON sleep_periods (start_utc);
CREATE INDEX idx_workouts_start ON workouts (start_utc);
CREATE INDEX idx_sync_log_created ON sync_log (created_at DESC);
CREATE INDEX idx_raw_object_day ON raw_object (day);
CREATE INDEX idx_raw_object_doc ON raw_object (source, endpoint, document_id);
CREATE INDEX idx_daily_sleep_updated ON daily_sleep (updated_at);
