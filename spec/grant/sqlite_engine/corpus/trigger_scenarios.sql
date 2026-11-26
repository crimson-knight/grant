-- Trigger scenarios for scripts/sqlite_engine_trigger_differential.cr: each
-- runs on a fresh pair of files, C SQLite 3.51.0 against the engine.

-- scenario: updated_at touch trigger
CREATE TABLE posts(id INTEGER PRIMARY KEY, title TEXT NOT NULL, body TEXT, updated_at TEXT);
CREATE TRIGGER posts_touch AFTER UPDATE ON posts FOR EACH ROW BEGIN UPDATE posts SET updated_at = 'touched' WHERE id = NEW.id; END;
INSERT INTO posts(title, body) VALUES ('a', 'x'), ('b', 'y');
UPDATE posts SET body = 'z' WHERE id = 1;
SELECT id, title, body, updated_at FROM posts ORDER BY id;
UPDATE posts SET title = title || '!';
SELECT id, title, updated_at FROM posts ORDER BY id;
SELECT changes(), total_changes();
PRAGMA recursive_triggers = ON;
UPDATE posts SET body = 'w' WHERE id = 2 AND updated_at IS NULL;
SELECT * FROM posts ORDER BY id;

-- scenario: updated_at touch with CURRENT_TIMESTAMP and WHEN guard
CREATE TABLE users(id INTEGER PRIMARY KEY, email TEXT UNIQUE, created_at TEXT, updated_at TEXT);
CREATE TRIGGER users_updated AFTER UPDATE ON users WHEN NEW.updated_at IS OLD.updated_at BEGIN
  UPDATE users SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
END;
INSERT INTO users(email, created_at, updated_at) VALUES ('a@x', '2026', '2026');
UPDATE users SET email = 'b@x';
SELECT id, email, updated_at <> '2026', length(updated_at) FROM users;
UPDATE users SET email = 'c@x', updated_at = 'manual';
SELECT * FROM users;

-- scenario: audit log inserts for insert update delete
CREATE TABLE accounts(id INTEGER PRIMARY KEY, owner TEXT, balance REAL DEFAULT 0);
CREATE TABLE audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, action TEXT, account_id INTEGER, old_balance, new_balance, note TEXT);
CREATE TRIGGER accounts_ai AFTER INSERT ON accounts BEGIN INSERT INTO audit(action, account_id, new_balance) VALUES ('insert', NEW.id, NEW.balance); END;
CREATE TRIGGER accounts_au AFTER UPDATE OF balance ON accounts BEGIN INSERT INTO audit(action, account_id, old_balance, new_balance) VALUES ('update', OLD.id, OLD.balance, NEW.balance); END;
CREATE TRIGGER accounts_ad AFTER DELETE ON accounts BEGIN INSERT INTO audit(action, account_id, old_balance, note) VALUES ('delete', OLD.id, OLD.balance, OLD.owner); END;
INSERT INTO accounts(owner, balance) VALUES ('ann', 10), ('bob', 20);
SELECT last_insert_rowid(), changes(), total_changes();
UPDATE accounts SET balance = balance + 5;
UPDATE accounts SET owner = 'BOB' WHERE id = 2;
DELETE FROM accounts WHERE owner = 'ann';
SELECT changes();
SELECT * FROM audit ORDER BY seq;
SELECT typeof(new_balance), typeof(old_balance) FROM audit ORDER BY seq;
SELECT * FROM sqlite_sequence;
INSERT OR REPLACE INTO accounts(id, owner, balance) VALUES (2, 'carl', 1);
SELECT * FROM audit ORDER BY seq;
PRAGMA recursive_triggers = 1;
INSERT OR REPLACE INTO accounts(id, owner, balance) VALUES (2, 'dina', 2);
SELECT * FROM audit ORDER BY seq;

-- scenario: soft delete guard with RAISE ABORT
CREATE TABLE documents(id INTEGER PRIMARY KEY, name TEXT, deleted_at TEXT);
CREATE TRIGGER documents_no_hard_delete BEFORE DELETE ON documents WHEN OLD.deleted_at IS NULL BEGIN
  SELECT RAISE(ABORT, 'soft delete documents instead');
END;
INSERT INTO documents(name) VALUES ('one'), ('two'), ('three');
DELETE FROM documents WHERE id = 1;
SELECT count(*) FROM documents;
UPDATE documents SET deleted_at = 'now' WHERE id = 2;
DELETE FROM documents WHERE id = 2;
DELETE FROM documents;
SELECT * FROM documents ORDER BY id;
BEGIN;
INSERT INTO documents(name) VALUES ('four');
DELETE FROM documents WHERE name = 'four';
SELECT * FROM documents ORDER BY id;
COMMIT;
SELECT * FROM documents ORDER BY id;

-- scenario: RAISE FAIL ROLLBACK and IGNORE
CREATE TABLE t(a INTEGER PRIMARY KEY, b);
CREATE TABLE seen(x);
CREATE TRIGGER t_bi BEFORE INSERT ON t BEGIN
  INSERT INTO seen VALUES (NEW.b);
  SELECT RAISE(IGNORE) WHERE NEW.b = 'skip';
  SELECT RAISE(FAIL, 'fail on ' || NEW.b) WHERE NEW.b = 'fail';
  SELECT RAISE(ROLLBACK, 'rollback') WHERE NEW.b = 'rollback';
END;
INSERT INTO t(b) VALUES ('one'), ('skip'), ('two');
SELECT changes(), last_insert_rowid();
SELECT * FROM t ORDER BY a;
INSERT INTO t(b) VALUES ('three'), ('fail'), ('four');
SELECT * FROM t ORDER BY a;
BEGIN;
INSERT INTO t(b) VALUES ('five');
INSERT INTO t(b) VALUES ('rollback');
SELECT * FROM t ORDER BY a;
INSERT INTO t(b) VALUES ('six');
SELECT * FROM t ORDER BY a;
SELECT * FROM seen;
SELECT RAISE(ABORT, 'outside');
CREATE TRIGGER bad AFTER INSERT ON t BEGIN SELECT ?; END;

-- scenario: BEFORE INSERT sees rowid -1 and affinity
CREATE TABLE r(id INTEGER PRIMARY KEY, n INTEGER, x REAL, s TEXT, g AS (n * 2));
CREATE TABLE out(a, b, c, d, e, f);
CREATE TRIGGER r_bi BEFORE INSERT ON r BEGIN INSERT INTO out VALUES (NEW.rowid, NEW.id, NEW.n, typeof(NEW.n), NEW.x, NEW.g); END;
CREATE TRIGGER r_ai AFTER INSERT ON r BEGIN INSERT INTO out VALUES (NEW.rowid, NEW.id, NEW.n, typeof(NEW.x), last_insert_rowid(), NEW.s); END;
INSERT INTO r(n, x, s) VALUES ('5', 3, 7);
INSERT INTO r(id, n, x, s) VALUES ('10', 6.0, '2.5', 1.5);
INSERT INTO r(n) SELECT n + 1 FROM r;
SELECT * FROM out;
SELECT last_insert_rowid();
DELETE FROM out;
CREATE TRIGGER r_bu BEFORE UPDATE ON r BEGIN INSERT INTO out VALUES (OLD.id, NEW.id, OLD.n, NEW.n, typeof(NEW.n), NEW.g); END;
UPDATE r SET n = '7' WHERE id = 1;
UPDATE r SET id = id + 100 WHERE id = 10;
SELECT * FROM out;
SELECT * FROM r ORDER BY id;

-- scenario: BEFORE UPDATE trigger changes the row being updated
CREATE TABLE c(id INTEGER PRIMARY KEY, a, b, n INTEGER DEFAULT 0);
CREATE TRIGGER c_bu BEFORE UPDATE OF a ON c BEGIN UPDATE c SET b = 'from trigger', n = n + 1 WHERE id = OLD.id; END;
INSERT INTO c(a, b) VALUES (1, 'x'), (2, 'y');
UPDATE c SET a = a + 10;
SELECT * FROM c ORDER BY id;
UPDATE c SET b = 'direct';
SELECT * FROM c ORDER BY id;
CREATE TRIGGER c_bd BEFORE DELETE ON c BEGIN DELETE FROM c WHERE id = OLD.id + 1; END;
DELETE FROM c;
SELECT changes(), total_changes();
SELECT * FROM c ORDER BY id;
CREATE TRIGGER c_bu2 BEFORE UPDATE OF b ON c BEGIN DELETE FROM c WHERE id = OLD.id; END;
INSERT INTO c(id, a, b) VALUES (5, 5, 5), (6, 6, 6);
UPDATE c SET b = 'gone';
SELECT changes();
SELECT * FROM c ORDER BY id;

-- scenario: UPDATE OF column lists
CREATE TABLE u(id INTEGER PRIMARY KEY, a, b, c);
CREATE TABLE ulog(what);
CREATE TRIGGER u_a AFTER UPDATE OF a ON u BEGIN INSERT INTO ulog VALUES ('a ' || NEW.a); END;
CREATE TRIGGER u_bc AFTER UPDATE OF b, c ON u BEGIN INSERT INTO ulog VALUES ('bc ' || NEW.b || NEW.c); END;
CREATE TRIGGER u_any AFTER UPDATE ON u BEGIN INSERT INTO ulog VALUES ('any'); END;
INSERT INTO u VALUES (1, 1, 1, 1);
UPDATE u SET a = 2;
UPDATE u SET c = 3;
UPDATE u SET id = 1;
UPDATE u SET rowid = 1;
UPDATE u SET (a, b) = (5, 6);
UPDATE u SET A = 7;
SELECT * FROM ulog;

-- scenario: trigger firing order and WHEN
CREATE TABLE o(x);
CREATE TABLE olog(n, v);
CREATE TRIGGER o1 AFTER INSERT ON o BEGIN INSERT INTO olog VALUES (1, NEW.x); END;
CREATE TRIGGER o2 AFTER INSERT ON o WHEN NEW.x > 5 BEGIN INSERT INTO olog VALUES (2, NEW.x); END;
CREATE TRIGGER o3 BEFORE INSERT ON o BEGIN INSERT INTO olog VALUES (3, NEW.x); END;
CREATE TRIGGER o4 AFTER INSERT ON o WHEN NEW.x IS NULL BEGIN INSERT INTO olog VALUES (4, 'null'); END;
INSERT INTO o VALUES (1), (10), (NULL);
SELECT rowid, * FROM olog ORDER BY rowid;
DROP TRIGGER o1;
DROP TRIGGER IF EXISTS o1;
DROP TRIGGER o1;
INSERT INTO o VALUES (20);
SELECT rowid, * FROM olog ORDER BY rowid;
SELECT name, tbl_name FROM sqlite_master WHERE type = 'trigger' ORDER BY name;

-- scenario: FTS-style sync triggers on ordinary tables
CREATE TABLE notes(id INTEGER PRIMARY KEY, title TEXT, content TEXT);
CREATE TABLE notes_index(rowid INTEGER PRIMARY KEY, title TEXT, content TEXT);
CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN
  INSERT INTO notes_index(rowid, title, content) VALUES (new.id, new.title, new.content);
END;
CREATE TRIGGER notes_ad AFTER DELETE ON notes BEGIN
  DELETE FROM notes_index WHERE rowid = old.id;
END;
CREATE TRIGGER notes_au AFTER UPDATE ON notes BEGIN
  DELETE FROM notes_index WHERE rowid = old.id;
  INSERT INTO notes_index(rowid, title, content) VALUES (new.id, new.title, new.content);
END;
INSERT INTO notes(title, content) VALUES ('t1', 'c1'), ('t2', 'c2'), ('t3', 'c3');
UPDATE notes SET content = upper(content) WHERE id >= 2;
DELETE FROM notes WHERE id = 1;
SELECT * FROM notes_index ORDER BY rowid;
SELECT changes(), total_changes();
UPDATE notes SET id = id + 10;
SELECT * FROM notes_index ORDER BY rowid;

-- scenario: counters maintained by triggers
CREATE TABLE authors(id INTEGER PRIMARY KEY, name TEXT, books_count INTEGER NOT NULL DEFAULT 0);
CREATE TABLE books(id INTEGER PRIMARY KEY, author_id INTEGER REFERENCES authors(id) ON DELETE CASCADE, title TEXT);
CREATE TRIGGER books_count_up AFTER INSERT ON books BEGIN UPDATE authors SET books_count = books_count + 1 WHERE id = NEW.author_id; END;
CREATE TRIGGER books_count_down AFTER DELETE ON books BEGIN UPDATE authors SET books_count = books_count - 1 WHERE id = OLD.author_id; END;
CREATE TRIGGER books_count_move AFTER UPDATE OF author_id ON books BEGIN
  UPDATE authors SET books_count = books_count - 1 WHERE id = OLD.author_id;
  UPDATE authors SET books_count = books_count + 1 WHERE id = NEW.author_id;
END;
INSERT INTO authors(name) VALUES ('a'), ('b');
INSERT INTO books(author_id, title) VALUES (1, 'x'), (1, 'y'), (2, 'z');
UPDATE books SET author_id = 2 WHERE title = 'x';
SELECT * FROM authors ORDER BY id;
PRAGMA foreign_keys = ON;
CREATE TABLE deleted_books(id, title);
CREATE TRIGGER books_archive BEFORE DELETE ON books BEGIN INSERT INTO deleted_books VALUES (OLD.id, OLD.title); END;
DELETE FROM authors WHERE id = 2;
SELECT changes(), total_changes();
SELECT * FROM books ORDER BY id;
SELECT * FROM deleted_books ORDER BY id;
SELECT * FROM authors ORDER BY id;
DROP TABLE books;
SELECT name FROM sqlite_master WHERE type = 'trigger';

-- scenario: INSTEAD OF triggers on views
CREATE TABLE people(id INTEGER PRIMARY KEY, first_name TEXT, last_name TEXT);
CREATE VIEW people_view AS SELECT id, first_name || ' ' || last_name AS full_name, first_name, last_name FROM people;
CREATE TRIGGER people_view_insert INSTEAD OF INSERT ON people_view BEGIN
  INSERT INTO people(first_name, last_name) VALUES (NEW.first_name, NEW.last_name);
END;
CREATE TRIGGER people_view_update INSTEAD OF UPDATE OF first_name ON people_view BEGIN
  UPDATE people SET first_name = NEW.first_name WHERE id = OLD.id;
END;
CREATE TRIGGER people_view_delete INSTEAD OF DELETE ON people_view BEGIN
  DELETE FROM people WHERE id = OLD.id;
END;
INSERT INTO people_view(first_name, last_name) VALUES ('Ada', 'Lovelace'), ('Alan', 'Turing');
SELECT changes(), total_changes(), last_insert_rowid();
SELECT * FROM people_view ORDER BY id;
UPDATE people_view SET first_name = 'Augusta' WHERE last_name = 'Lovelace';
UPDATE people_view SET last_name = 'nothing fires';
SELECT * FROM people ORDER BY id;
DELETE FROM people_view WHERE id = 2;
SELECT * FROM people ORDER BY id;
INSERT INTO people_view(nope) VALUES (1);
CREATE TRIGGER bad_view BEFORE INSERT ON people_view BEGIN SELECT 1; END;
CREATE TRIGGER bad_table INSTEAD OF INSERT ON people BEGIN SELECT 1; END;
DROP VIEW people_view;
SELECT name FROM sqlite_master WHERE type = 'trigger';

-- scenario: CREATE TRIGGER text and errors
CREATE TABLE t(a, b);
CREATE TRIGGER IF NOT EXISTS "Quoted Name"   AFTER INSERT ON T FOR EACH ROW  WHEN new.a > 0 /* comment */ BEGIN insert into t select a, b from t where 0; END;
CREATE TRIGGER main.qualified BEFORE DELETE ON t BEGIN SELECT CASE WHEN 1 THEN 2 END; END ;
CREATE TRIGGER IF NOT EXISTS qualified BEFORE DELETE ON t BEGIN SELECT 1; END;
CREATE TRIGGER qualified BEFORE DELETE ON t BEGIN SELECT 1; END;
CREATE TRIGGER "QUALIFIED" BEFORE DELETE ON t BEGIN SELECT 1; END;
CREATE TRIGGER x AFTER INSERT ON nosuch BEGIN SELECT 1; END;
CREATE TRIGGER sqlite_x AFTER INSERT ON t BEGIN SELECT 1; END;
CREATE TRIGGER x AFTER INSERT ON sqlite_master BEGIN SELECT 1; END;
CREATE TRIGGER x AFTER INSERT ON temp.t BEGIN SELECT 1; END;
CREATE TRIGGER nope.x AFTER INSERT ON t BEGIN SELECT 1; END;
CREATE TRIGGER x AFTER INSERT ON t BEGIN INSERT INTO nosuch VALUES (1); END;
INSERT INTO t VALUES (1, 2);
DROP TRIGGER x;
CREATE TRIGGER x AFTER INSERT ON t BEGIN UPDATE t SET b = old.a; END;
INSERT INTO t VALUES (1, 2);
DROP TRIGGER x;
CREATE TRIGGER x AFTER DELETE ON t BEGIN UPDATE t SET b = new.a; END;
DELETE FROM t;
DROP TRIGGER x;
DROP TRIGGER nosuch;
DROP TRIGGER main.nosuch;
DROP TRIGGER IF EXISTS main.nosuch;
SELECT type, name, tbl_name, rootpage, sql FROM sqlite_master ORDER BY name;
PRAGMA integrity_check;

-- scenario: TEMP triggers
CREATE TABLE m(a);
CREATE TABLE mlog(x);
CREATE TEMP TRIGGER m_temp AFTER INSERT ON m BEGIN INSERT INTO mlog VALUES ('temp ' || NEW.a); END;
CREATE TRIGGER m_main AFTER INSERT ON m BEGIN INSERT INTO mlog VALUES ('main ' || NEW.a); END;
CREATE TEMP TRIGGER m_temp2 AFTER INSERT ON main.m BEGIN INSERT INTO mlog VALUES ('temp2 ' || NEW.a); END;
INSERT INTO m VALUES (1);
SELECT rowid, x FROM mlog ORDER BY rowid;
SELECT type, name, tbl_name, sql FROM sqlite_temp_master ORDER BY name;
DROP TRIGGER m_temp;
INSERT INTO m VALUES (2);
SELECT rowid, x FROM mlog ORDER BY rowid;
DROP TABLE m;
SELECT type, name FROM sqlite_temp_master;

-- scenario: nested triggers and recursion
CREATE TABLE n1(x);
CREATE TABLE n2(x);
CREATE TABLE n3(x);
CREATE TRIGGER n1_ai AFTER INSERT ON n1 BEGIN INSERT INTO n2 VALUES (NEW.x * 10); END;
CREATE TRIGGER n2_ai AFTER INSERT ON n2 BEGIN INSERT INTO n3 VALUES (NEW.x + 1); INSERT INTO n1 SELECT NEW.x WHERE NEW.x < 1000; END;
INSERT INTO n1 VALUES (1);
SELECT changes(), total_changes(), last_insert_rowid();
SELECT * FROM n1;
SELECT * FROM n2;
SELECT * FROM n3;
PRAGMA recursive_triggers = ON;
INSERT INTO n1 VALUES (2);
SELECT * FROM n1;
SELECT * FROM n2;
SELECT * FROM n3;
CREATE TABLE fib(n INTEGER PRIMARY KEY, v);
CREATE TRIGGER fib_next AFTER INSERT ON fib WHEN NEW.n < 30 BEGIN INSERT INTO fib VALUES (NEW.n + 1, NEW.v + coalesce((SELECT v FROM fib WHERE n = NEW.n - 1), 0)); END;
INSERT INTO fib VALUES (1, 1);
SELECT count(*), max(v) FROM fib;
SELECT total_changes();

-- scenario: upsert fires update triggers
CREATE TABLE kv(k TEXT PRIMARY KEY, v, hits INTEGER DEFAULT 0);
CREATE TABLE kvlog(e);
CREATE TRIGGER kv_bi BEFORE INSERT ON kv BEGIN INSERT INTO kvlog VALUES ('bi ' || NEW.k); END;
CREATE TRIGGER kv_ai AFTER INSERT ON kv BEGIN INSERT INTO kvlog VALUES ('ai ' || NEW.k); END;
CREATE TRIGGER kv_bu BEFORE UPDATE ON kv BEGIN INSERT INTO kvlog VALUES ('bu ' || OLD.v || '>' || NEW.v); END;
CREATE TRIGGER kv_au AFTER UPDATE ON kv BEGIN INSERT INTO kvlog VALUES ('au ' || NEW.hits); END;
INSERT INTO kv(k, v) VALUES ('a', 1) ON CONFLICT(k) DO UPDATE SET v = excluded.v, hits = hits + 1;
INSERT INTO kv(k, v) VALUES ('a', 2) ON CONFLICT(k) DO UPDATE SET v = excluded.v, hits = hits + 1;
INSERT OR IGNORE INTO kv(k, v) VALUES ('a', 3);
INSERT INTO kv(k, v) VALUES ('a', 4) ON CONFLICT DO NOTHING;
SELECT * FROM kv;
SELECT rowid, e FROM kvlog ORDER BY rowid;

-- scenario: trigger body conflict policy follows the firing statement
CREATE TABLE src(a);
CREATE TABLE dst(a UNIQUE, b);
CREATE TRIGGER src_ai AFTER INSERT ON src BEGIN INSERT INTO dst VALUES (NEW.a, 'first'); INSERT OR IGNORE INTO dst VALUES (NEW.a, 'second'); END;
INSERT INTO src VALUES (1);
SELECT * FROM dst;
INSERT OR REPLACE INTO src VALUES (1);
SELECT * FROM dst;
INSERT OR ABORT INTO src VALUES (2);
SELECT * FROM dst;
SELECT * FROM src;
INSERT OR FAIL INTO src VALUES (3), (1);
SELECT * FROM src;

-- scenario: last_insert_rowid and changes inside triggers
CREATE TABLE a(id INTEGER PRIMARY KEY, v);
CREATE TABLE b(id INTEGER PRIMARY KEY, v);
CREATE TABLE info(lir, ch, tc);
INSERT INTO b(id, v) VALUES (100, 'seed');
CREATE TRIGGER a_ai AFTER INSERT ON a BEGIN
  INSERT INTO b(v) VALUES (NEW.v);
  INSERT INTO info VALUES (last_insert_rowid(), changes(), 0);
  UPDATE b SET v = v || '+' WHERE id > 0;
  INSERT INTO info VALUES (last_insert_rowid(), changes(), 1);
END;
INSERT INTO a(v) VALUES ('x');
SELECT last_insert_rowid(), changes();
INSERT INTO a(v) VALUES ('y'), ('z');
SELECT last_insert_rowid(), changes();
SELECT * FROM info;
SELECT * FROM b ORDER BY id;

-- scenario: subqueries and joins reading NEW and OLD
CREATE TABLE orders(id INTEGER PRIMARY KEY, customer TEXT, total REAL);
CREATE TABLE totals(customer TEXT PRIMARY KEY, amount REAL, orders INTEGER);
CREATE TRIGGER orders_ai AFTER INSERT ON orders BEGIN
  INSERT OR IGNORE INTO totals VALUES (NEW.customer, 0, 0);
  UPDATE totals SET amount = (SELECT sum(total) FROM orders WHERE customer = NEW.customer),
    orders = (SELECT count(*) FROM orders o WHERE o.customer = NEW.customer) WHERE customer = NEW.customer;
END;
CREATE TRIGGER orders_ad AFTER DELETE ON orders WHEN EXISTS (SELECT 1 FROM totals WHERE customer = OLD.customer) BEGIN
  UPDATE totals SET amount = amount - OLD.total, orders = orders - 1 WHERE customer = OLD.customer;
  DELETE FROM totals WHERE customer = OLD.customer AND orders = 0;
END;
INSERT INTO orders(customer, total) VALUES ('x', 10), ('y', 5), ('x', 2.5);
SELECT * FROM totals ORDER BY customer;
DELETE FROM orders WHERE customer = 'y';
DELETE FROM orders WHERE id = 1;
SELECT * FROM totals ORDER BY customer;
CREATE TRIGGER orders_bu BEFORE UPDATE ON orders WHEN NEW.total < 0 BEGIN SELECT RAISE(ABORT, 'negative total for ' || OLD.customer); END;
UPDATE orders SET total = -1;
UPDATE orders SET total = 3;
SELECT * FROM orders ORDER BY id;

-- scenario: ALTER TABLE RENAME keeps triggers
CREATE TABLE old_name(id INTEGER PRIMARY KEY, v);
CREATE TABLE rlog(x);
CREATE TRIGGER old_name_ai AFTER INSERT ON old_name BEGIN INSERT INTO rlog VALUES (NEW.v); END;
INSERT INTO old_name(v) VALUES ('before');
ALTER TABLE old_name RENAME TO new_name;
SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY name;
INSERT INTO new_name(v) VALUES ('after');
SELECT * FROM rlog;

-- scenario: migration rebuild of a table with triggers
CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT, updated_at TEXT);
CREATE TRIGGER items_touch AFTER UPDATE ON items BEGIN UPDATE items SET updated_at = 'touched' WHERE id = NEW.id; END;
INSERT INTO items(name) VALUES ('a'), ('b');
BEGIN;
CREATE TABLE items_new(id INTEGER PRIMARY KEY, name TEXT NOT NULL, price REAL DEFAULT 0, updated_at TEXT);
INSERT INTO items_new(id, name, updated_at) SELECT id, name, updated_at FROM items;
DROP TABLE items;
ALTER TABLE items_new RENAME TO items;
CREATE TRIGGER items_touch AFTER UPDATE ON items BEGIN UPDATE items SET updated_at = 'touched again' WHERE id = NEW.id; END;
COMMIT;
UPDATE items SET price = 2 WHERE id = 1;
SELECT * FROM items ORDER BY id;
SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY name;

-- scenario: engine reads triggers C wrote
CREATE TABLE w(id INTEGER PRIMARY KEY, v);
CREATE TABLE wlog(x);
CREATE TRIGGER w_ai AFTER INSERT ON w BEGIN INSERT INTO wlog VALUES ('ai ' || NEW.v); END;
CREATE TRIGGER w_bd BEFORE DELETE ON w WHEN OLD.v = 'keep' BEGIN SELECT RAISE(ABORT, 'kept'); END;
CREATE VIEW wv AS SELECT id, v FROM w;
CREATE TRIGGER wv_ins INSTEAD OF INSERT ON wv BEGIN INSERT INTO w(v) VALUES (upper(NEW.v)); END;
INSERT INTO w(v) VALUES ('one');
-- swap
INSERT INTO w(v) VALUES ('keep'), ('two');
INSERT INTO wv(v) VALUES ('three');
DELETE FROM w;
DELETE FROM w WHERE v <> 'keep';
SELECT * FROM w ORDER BY id;
SELECT * FROM wlog;
DROP TRIGGER w_bd;
DELETE FROM w;
SELECT count(*) FROM w;

-- scenario: WITHOUT ROWID and generated columns
CREATE TABLE wr(k TEXT PRIMARY KEY, v INTEGER, g AS (v + 1) STORED) WITHOUT ROWID;
CREATE TABLE wrlog(a, b, c, d);
CREATE TRIGGER wr_au AFTER UPDATE ON wr BEGIN INSERT INTO wrlog VALUES (OLD.k, OLD.g, NEW.k, NEW.g); END;
CREATE TRIGGER wr_ad AFTER DELETE ON wr BEGIN INSERT INTO wrlog VALUES (OLD.k, OLD.v, OLD.g, NULL); END;
INSERT INTO wr(k, v) VALUES ('a', 1), ('b', 2);
UPDATE wr SET v = v * 10;
UPDATE wr SET k = k || k WHERE k = 'a';
DELETE FROM wr WHERE k = 'b';
SELECT * FROM wrlog;
SELECT * FROM wr;

-- scenario: collation and affinity of NEW and OLD
CREATE TABLE ci(id INTEGER PRIMARY KEY, name TEXT COLLATE NOCASE, n INTEGER);
CREATE TABLE cilog(a, b, c, d);
CREATE TRIGGER ci_ai AFTER INSERT ON ci BEGIN INSERT INTO cilog VALUES (NEW.name = 'ADA', NEW.n = '5', NEW.n < '10', NEW.id = '1'); END;
INSERT INTO ci(name, n) VALUES ('ada', 5);
SELECT * FROM cilog;

-- scenario: statement transaction undone after a trigger error
CREATE TABLE p(id INTEGER PRIMARY KEY, v);
CREATE TABLE q(v NOT NULL);
CREATE TRIGGER p_ai AFTER INSERT ON p BEGIN INSERT INTO q VALUES (NEW.v); END;
INSERT INTO p(v) VALUES (1), (2), (NULL), (3);
SELECT changes(), total_changes();
SELECT * FROM p;
SELECT * FROM q;
BEGIN;
INSERT INTO p(v) VALUES (4);
INSERT INTO p(v) VALUES (5), (NULL);
SELECT * FROM p;
SELECT * FROM q;
COMMIT;
SELECT * FROM p;
INSERT OR IGNORE INTO p(v) VALUES (6), (NULL), (7);
SELECT * FROM q;

-- scenario: recursion limit
CREATE TABLE t(x);
CREATE TRIGGER r AFTER INSERT ON t BEGIN INSERT INTO t VALUES (new.x + 1); END;
INSERT INTO t VALUES (1);
SELECT count(*) FROM t;
PRAGMA recursive_triggers = 1;
INSERT INTO t VALUES (1);
SELECT count(*), max(x) FROM t;
CREATE TABLE d(x);
CREATE TRIGGER dr AFTER INSERT ON d WHEN new.x < 500 BEGIN INSERT INTO d VALUES (new.x + 1); END;
INSERT INTO d VALUES (1);
SELECT count(*), max(x), total_changes() FROM d;
CREATE TRIGGER dd AFTER DELETE ON d BEGIN DELETE FROM d WHERE x = old.x + 1; END;
DELETE FROM d WHERE x = 1;
SELECT count(*), changes(), total_changes() FROM d;
-- scenario: alter columns with triggers
CREATE TABLE a(id INTEGER PRIMARY KEY, b, c);
CREATE TABLE alog(v);
CREATE TRIGGER a_ai AFTER INSERT ON a BEGIN INSERT INTO alog VALUES (new.b); END;
CREATE TRIGGER a_au AFTER UPDATE OF c ON a BEGIN INSERT INTO alog VALUES (new.c); END;
ALTER TABLE a ADD COLUMN d DEFAULT 4;
INSERT INTO a(b, c) VALUES (1, 2);
ALTER TABLE a DROP COLUMN d;
ALTER TABLE a DROP COLUMN b;
ALTER TABLE a DROP COLUMN c;
ALTER TABLE a RENAME COLUMN b TO bb;
SELECT sql FROM sqlite_master WHERE type = 'trigger' ORDER BY name;
INSERT INTO a(bb, c) VALUES (5, 6);
UPDATE a SET c = 7;
SELECT * FROM alog;
-- scenario: foreign key cascade fires child triggers
PRAGMA foreign_keys = ON;
CREATE TABLE parent(id INTEGER PRIMARY KEY);
CREATE TABLE child(id INTEGER PRIMARY KEY, parent_id REFERENCES parent(id) ON DELETE CASCADE ON UPDATE CASCADE, note);
CREATE TABLE clog(e);
CREATE TRIGGER child_bd BEFORE DELETE ON child BEGIN INSERT INTO clog VALUES ('bd ' || old.id); END;
CREATE TRIGGER child_ad AFTER DELETE ON child BEGIN INSERT INTO clog VALUES ('ad ' || old.id); END;
CREATE TRIGGER child_au AFTER UPDATE OF parent_id ON child BEGIN INSERT INTO clog VALUES ('au ' || old.parent_id || '>' || new.parent_id); END;
INSERT INTO parent VALUES (1), (2);
INSERT INTO child(parent_id) VALUES (1), (1), (2);
UPDATE parent SET id = 10 WHERE id = 1;
DELETE FROM parent WHERE id = 2;
SELECT changes(), total_changes();
SELECT * FROM child ORDER BY id;
SELECT rowid, e FROM clog ORDER BY rowid;
CREATE TRIGGER parent_guard BEFORE DELETE ON parent BEGIN SELECT RAISE(ABORT, 'parents stay'); END;
DELETE FROM parent;
SELECT count(*) FROM child;
-- scenario: json and date functions in bodies
CREATE TABLE ev(id INTEGER PRIMARY KEY, payload TEXT);
CREATE TABLE ev_out(kind, at);
CREATE TRIGGER ev_ai AFTER INSERT ON ev WHEN json_valid(new.payload) BEGIN
  INSERT INTO ev_out SELECT value, date('2026-01-01', '+' || new.id || ' days') FROM json_each(new.payload, '$.kinds');
END;
INSERT INTO ev(payload) VALUES ('{"kinds":["a","b"]}'), ('not json'), ('{"kinds":[1]}');
SELECT * FROM ev_out ORDER BY rowid;
-- scenario: RAISE in WHEN and in UPDATE SET
CREATE TABLE g(x);
CREATE TRIGGER g1 BEFORE INSERT ON g WHEN RAISE(IGNORE) IS NULL BEGIN SELECT 1; END;
INSERT INTO g VALUES (1);
SELECT count(*) FROM g;
DROP TRIGGER g1;
CREATE TABLE h(y);
CREATE TRIGGER g2 AFTER INSERT ON g BEGIN UPDATE h SET y = CASE WHEN new.x > 5 THEN RAISE(FAIL, 'big ' || new.x) ELSE new.x END; INSERT INTO h VALUES (new.x); END;
INSERT INTO g VALUES (1), (2), (9), (3);
SELECT * FROM g;
SELECT * FROM h;

-- scenario: schema_version moves once per CREATE and DROP TRIGGER
CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT);
CREATE TEMP TABLE scratch(x);
PRAGMA schema_version;
CREATE TRIGGER notes_guard BEFORE DELETE ON notes BEGIN SELECT RAISE(ABORT, 'locked'); END;
CREATE TEMP TRIGGER notes_temp AFTER INSERT ON notes BEGIN INSERT INTO scratch VALUES (new.id); END;
PRAGMA schema_version;
SELECT type, name, tbl_name FROM sqlite_temp_master ORDER BY name;
DROP TRIGGER notes_guard;
PRAGMA schema_version;
DROP TRIGGER IF EXISTS notes_guard;
PRAGMA schema_version;
DROP TABLE notes;
PRAGMA schema_version;
SELECT type, name, tbl_name FROM sqlite_temp_master ORDER BY name;
