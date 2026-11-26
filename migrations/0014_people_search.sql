DROP INDEX IF EXISTS idx_calendar_event_active_start;

-- Cover date-scoped reads using UTC boundaries in the viewer's time zone.
CREATE INDEX idx_calendar_event_active_start
  ON calendar_event (start_utc, id, source) WHERE deleted_at IS NULL;

-- One searchable row per email. The projection is updated by SQLite so
-- existing calendar and name writes keep the index current.
CREATE TABLE people_directory (
  id INTEGER PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  name TEXT
);

CREATE VIRTUAL TABLE people_search USING fts5 (
  email, name, content='people_directory', content_rowid='id',
  tokenize='unicode61 remove_diacritics 2', prefix='1 2 3 4'
);

CREATE VIRTUAL TABLE people_search_trigrams USING fts5 (
  email, name, content='people_directory', content_rowid='id',
  tokenize='trigram remove_diacritics 1'
);

CREATE TRIGGER people_directory_insert AFTER INSERT ON people_directory BEGIN
  INSERT INTO people_search (rowid, email, name) VALUES (new.id, new.email, new.name);
  INSERT INTO people_search_trigrams (rowid, email, name) VALUES (new.id, new.email, new.name);
END;
CREATE TRIGGER people_directory_delete AFTER DELETE ON people_directory BEGIN
  INSERT INTO people_search (people_search, rowid, email, name) VALUES ('delete', old.id, old.email, old.name);
  INSERT INTO people_search_trigrams (people_search_trigrams, rowid, email, name) VALUES ('delete', old.id, old.email, old.name);
END;
CREATE TRIGGER people_directory_update AFTER UPDATE ON people_directory BEGIN
  INSERT INTO people_search (people_search, rowid, email, name) VALUES ('delete', old.id, old.email, old.name);
  INSERT INTO people_search_trigrams (people_search_trigrams, rowid, email, name) VALUES ('delete', old.id, old.email, old.name);
  INSERT INTO people_search (rowid, email, name) VALUES (new.id, new.email, new.name);
  INSERT INTO people_search_trigrams (rowid, email, name) VALUES (new.id, new.email, new.name);
END;

CREATE VIEW people_directory_current AS
SELECT a.email,
  COALESCE(
    (SELECT trim(b.display_name)
       FROM calendar_attendee b JOIN calendar_event e ON e.id = b.event_id AND e.source = b.source
       WHERE b.email = a.email AND b.self = 0 AND e.deleted_at IS NULL
         AND trim(b.display_name) <> '' AND instr(b.display_name, '@') = 0
       ORDER BY e.start_utc DESC, b.event_id, b.source LIMIT 1),
    (SELECT name FROM person_name WHERE email = a.email)
  ) AS name
FROM (
  SELECT DISTINCT a.email
  FROM calendar_attendee a JOIN calendar_event e ON e.id = a.event_id AND e.source = a.source
  WHERE a.self = 0 AND e.deleted_at IS NULL
) a;

INSERT INTO people_directory (email, name) SELECT email, name FROM people_directory_current;

CREATE VIEW people_directory_refresh AS SELECT email FROM people_directory;
CREATE TRIGGER people_directory_refresh_email INSTEAD OF INSERT ON people_directory_refresh BEGIN
  INSERT INTO people_directory (email, name)
    SELECT email, name FROM people_directory_current WHERE email = new.email
    ON CONFLICT (email) DO UPDATE SET name = excluded.name WHERE people_directory.name IS NOT excluded.name;
  DELETE FROM people_directory
    WHERE email = new.email AND NOT EXISTS (SELECT 1 FROM people_directory_current WHERE email = new.email);
END;

CREATE TRIGGER people_attendee_insert AFTER INSERT ON calendar_attendee BEGIN
  INSERT INTO people_directory_refresh VALUES (new.email);
END;
CREATE TRIGGER people_attendee_delete AFTER DELETE ON calendar_attendee BEGIN
  INSERT INTO people_directory_refresh VALUES (old.email);
END;
CREATE TRIGGER people_attendee_update AFTER UPDATE ON calendar_attendee BEGIN
  INSERT INTO people_directory_refresh VALUES (new.email);
  INSERT INTO people_directory_refresh SELECT old.email WHERE old.email <> new.email;
END;

CREATE TRIGGER people_name_insert AFTER INSERT ON person_name BEGIN
  INSERT INTO people_directory_refresh VALUES (new.email);
END;
CREATE TRIGGER people_name_update AFTER UPDATE ON person_name
WHEN old.name IS NOT new.name OR old.email <> new.email BEGIN
  INSERT INTO people_directory_refresh VALUES (new.email);
  INSERT INTO people_directory_refresh SELECT old.email WHERE old.email <> new.email;
END;
CREATE TRIGGER people_name_delete AFTER DELETE ON person_name BEGIN
  INSERT INTO people_directory_refresh VALUES (old.email);
END;

CREATE TRIGGER people_event_update AFTER UPDATE OF deleted_at, start_utc ON calendar_event
WHEN (old.deleted_at IS NULL) <> (new.deleted_at IS NULL) OR old.start_utc <> new.start_utc BEGIN
  INSERT INTO people_directory_refresh
    SELECT email FROM calendar_attendee WHERE event_id = new.id AND source = new.source AND self = 0;
END;
CREATE TRIGGER people_event_delete AFTER DELETE ON calendar_event BEGIN
  INSERT INTO people_directory_refresh
    SELECT email FROM calendar_attendee WHERE event_id = old.id AND source = old.source AND self = 0;
END;
