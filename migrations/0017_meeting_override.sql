-- What the owner says about a meeting, and what the Mac saw of it. Keyed by
-- `event:<calendar_event.id>` for one meeting or `series:<id>` for every
-- meeting in a recurring series (the event id without Google's instance
-- suffix, _YYYYMMDD or _YYYYMMDDTHHMMSSZ). The calendar itself is never
-- edited: these rows only change how Meetspike reads a meeting.
--   state:         not_joined, unlinked (both leave the meeting out) or linked
--                  (keep it, even when its series says otherwise). NULL: no choice.
--   start/end_utc: times the owner set (events only).
--   seen_*:        first and last moment the Mac saw Zoom running around the
--                  meeting; seen_none = 1 when it watched and never saw it.
-- Nothing is deleted from heart rate tables. Code tolerates this table being
-- absent (migration not yet applied). 0001–0016 stay frozen.

CREATE TABLE IF NOT EXISTS meeting_override (
  key             TEXT PRIMARY KEY,
  state           TEXT CHECK (state IN ('not_joined', 'unlinked', 'linked')),
  start_utc       TEXT,
  end_utc         TEXT,
  seen_start_utc  TEXT,
  seen_end_utc    TEXT,
  seen_none       INTEGER NOT NULL DEFAULT 0,
  updated_at      TEXT NOT NULL
);
