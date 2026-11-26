-- One-time iPhone pairing codes (POST /api/pair/start, POST /hooks/pair).
-- In D1, not KV: redeeming is one DELETE ... RETURNING, so a code pays out
-- once even when two requests race, and a fresh code is readable at once
-- from any location. Only the SHA-256 of the code's secret half is stored.
CREATE TABLE IF NOT EXISTS pair_codes (
  id TEXT PRIMARY KEY,
  secret_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
