CREATE TABLE whoop_webhook_receipt (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  trace_id TEXT NOT NULL UNIQUE,
  event_type TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX idx_whoop_webhook_receipt_expiry ON whoop_webhook_receipt (expires_at);

CREATE TRIGGER log_whoop_webhook_deletion
AFTER INSERT ON whoop_webhook_receipt
WHEN NEW.event_type LIKE '%.deleted'
BEGIN
  INSERT INTO sync_log (trigger, source, endpoint, status, error_text, event_id, created_at)
  VALUES ('webhook', 'whoop', NEW.event_type, 'partial', 'WHOOP deletion deferred', NEW.trace_id,
          strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
END;

CREATE TABLE whoop_webhook_sync (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  covered_through INTEGER NOT NULL DEFAULT 0,
  available_at INTEGER NOT NULL DEFAULT 0,
  owner TEXT
);

INSERT INTO whoop_webhook_sync (id) VALUES (1);
