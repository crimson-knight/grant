-- Column and table constraints every ORM can emit: STRICT, WITHOUT ROWID, generated columns,
-- CHECK, COLLATE, DEFAULT expressions, composite keys, deferrable foreign keys, conflict clauses.
CREATE TABLE accounts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  code TEXT NOT NULL UNIQUE COLLATE NOCASE,
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
  balance INTEGER NOT NULL DEFAULT 0 CHECK (balance >= 0),
  rate REAL DEFAULT 0.25,
  opened_on TEXT DEFAULT (date('now')) NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  token TEXT DEFAULT (lower(hex(zeroblob(2)))),
  flags INTEGER DEFAULT (1 << 3),
  negative INTEGER DEFAULT -1,
  plus REAL DEFAULT +2.5,
  blob_default BLOB DEFAULT x'00ff',
  label TEXT DEFAULT 'it''s' COLLATE RTRIM,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  UNIQUE (name, opened_on) ON CONFLICT REPLACE
);
CREATE TABLE ledger_entries (
  account_id INTEGER NOT NULL REFERENCES accounts (id) ON DELETE RESTRICT ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  entry_no INTEGER NOT NULL,
  amount INTEGER NOT NULL,
  memo TEXT,
  PRIMARY KEY (account_id, entry_no)
) WITHOUT ROWID;
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value ANY,
  updated_at INTEGER
) STRICT;
CREATE TABLE measurements (
  id INTEGER PRIMARY KEY,
  sensor TEXT NOT NULL,
  celsius REAL NOT NULL,
  fahrenheit REAL GENERATED ALWAYS AS (celsius * 9.0 / 5.0 + 32.0) STORED,
  label TEXT AS (sensor || ':' || celsius) VIRTUAL,
  reading_day TEXT GENERATED ALWAYS AS (substr(sensor, 1, 3))
);
CREATE TABLE strict_items (id INTEGER PRIMARY KEY, qty INTEGER NOT NULL, price REAL, name TEXT, data BLOB) STRICT, WITHOUT ROWID;
CREATE TABLE strict_rows (id INTEGER PRIMARY KEY, qty INTEGER NOT NULL, price REAL, name TEXT) STRICT;
CREATE TABLE "quoted names" ("first name" TEXT, [last name] TEXT, `nick` TEXT, "a""b" INTEGER);
CREATE TABLE IF NOT EXISTS accounts (id INTEGER);
CREATE TABLE accounts (id INTEGER);
CREATE TABLE no_type (a, b, c PRIMARY KEY);
CREATE TABLE conflicting (id INTEGER PRIMARY KEY ON CONFLICT IGNORE, n INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 7, u TEXT UNIQUE ON CONFLICT FAIL);
CREATE INDEX measurements_sensor ON measurements (sensor COLLATE NOCASE, celsius DESC);
CREATE INDEX measurements_label ON measurements (label);
CREATE INDEX accounts_open ON accounts (opened_on) WHERE status = 'open' AND balance > 0;
CREATE INDEX accounts_expr ON accounts (abs(balance), substr(name, 1, 2));
CREATE UNIQUE INDEX IF NOT EXISTS settings_updated ON settings (updated_at);
CREATE INDEX IF NOT EXISTS accounts_open ON accounts (status);
CREATE INDEX accounts_open ON accounts (status);
CREATE INDEX bad_index ON missing_table (x);
CREATE INDEX bad_column ON accounts (missing_column);
INSERT INTO accounts (code, name, balance) VALUES ('ACC1', 'Main', 100), ('acc2', 'Spare', 5);
INSERT INTO accounts (code, name) VALUES ('Acc1', 'Dup');
INSERT INTO accounts (code, name, balance) VALUES ('ACC3', 'Neg', -1);
INSERT INTO accounts (code, name, status) VALUES ('ACC4', 'Bad', 'frozen');
INSERT INTO accounts (code, name) VALUES ('ACC5', 'Main');
INSERT INTO ledger_entries VALUES (1, 1, 50, 'open'), (1, 2, -20, NULL), (2, 1, 5, 'x');
INSERT INTO ledger_entries VALUES (1, 1, 99, 'dup');
INSERT INTO settings VALUES ('theme', 'dark', 1), ('size', 12, 2), ('ratio', 1.5, 3);
INSERT INTO settings VALUES ('bad', 1, 'not an int');
INSERT INTO settings VALUES (NULL, 1, 1);
CREATE TABLE kv (k TEXT PRIMARY KEY, v) WITHOUT ROWID;
INSERT INTO kv VALUES (NULL, 1);
INSERT INTO kv VALUES ('a', 1);
INSERT INTO strict_rows VALUES (1, '3', '2.5', 4);
INSERT INTO strict_rows VALUES (2, 'x', 1, 'a');
INSERT INTO strict_items VALUES (1, 2, 3, 'n', x'01');
INSERT INTO measurements (sensor, celsius) VALUES ('kitchen', 21.5), ('garage', -3);
INSERT INTO measurements (sensor, celsius, fahrenheit) VALUES ('x', 1, 2);
INSERT INTO "quoted names" VALUES ('A', 'B', 'C', 1);
INSERT INTO no_type VALUES (1, '2', 3.0), ('1', 2, 3);
INSERT INTO conflicting VALUES (1, NULL, 'a');
INSERT INTO conflicting VALUES (1, 5, 'b');
INSERT INTO conflicting VALUES (2, 5, 'a');
SELECT * FROM measurements ORDER BY id;
PRAGMA table_xinfo(measurements);
PRAGMA index_xinfo(measurements_sensor);
PRAGMA index_xinfo(accounts_expr);
PRAGMA index_list(accounts);
PRAGMA index_list(ledger_entries);
PRAGMA table_list;
SELECT * FROM pragma_table_list ORDER BY schema, name;
SELECT name, ncol, wr, strict FROM pragma_table_list('measurements');
PRAGMA main.table_list(settings);
