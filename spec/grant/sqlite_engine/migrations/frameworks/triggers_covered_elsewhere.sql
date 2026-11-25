-- CREATE TRIGGER statements migrations write (updated_at touch, audit log, soft-delete guard).
-- Trigger support is the parallel S2 trigger chunk's work; differences here are listed as covered elsewhere.
CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, updated_at TEXT);
CREATE TABLE notes_audit (id INTEGER PRIMARY KEY, note_id INTEGER, action TEXT);
CREATE TRIGGER notes_touch AFTER UPDATE OF body ON notes FOR EACH ROW BEGIN UPDATE notes SET updated_at = '2026-11-25' WHERE id = NEW.id; END;
CREATE TRIGGER IF NOT EXISTS notes_log AFTER INSERT ON notes BEGIN INSERT INTO notes_audit (note_id, action) VALUES (NEW.id, 'insert'); END;
CREATE TRIGGER notes_guard BEFORE DELETE ON notes WHEN OLD.body = 'locked' BEGIN SELECT RAISE(ABORT, 'note is locked'); END;
INSERT INTO notes (body) VALUES ('a'), ('locked');
UPDATE notes SET body = 'b' WHERE id = 1;
DELETE FROM notes WHERE id = 2;
SELECT * FROM notes ORDER BY id;
SELECT * FROM notes_audit ORDER BY id;
DROP TRIGGER notes_guard;
DROP TRIGGER IF EXISTS notes_guard;
