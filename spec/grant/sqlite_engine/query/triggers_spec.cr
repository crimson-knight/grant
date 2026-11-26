require "spec"
require "../../../support/sqlite_engine/trigger_differential"

# CREATE TRIGGER and DROP TRIGGER on Grant's engine: what the triggers do,
# checked on the engine alone, then every scenario of the trigger corpus
# compared with C SQLite 3.51.0.
module TriggersSpecFixture
  alias V = Grant::SQLiteEngine::Value

  # A session on a new database file in a directory of its own.
  def self.with_session(& : Grant::SQLiteEngine::Query::Session ->) : Nil
    directory = File.join(Dir.tempdir, "grant-triggers-spec-#{Random::Secure.hex(6)}")
    Dir.mkdir_p(directory)
    path = File.join(directory, "triggers.db")
    pager = Grant::SQLiteEngine::Pager.open_read_write(Grant::SQLiteEngine::PosixFileSystem.new, path)
    session = Grant::SQLiteEngine::Query::Session.new(Grant::SQLiteEngine::Database.new(pager, path))
    begin
      yield session
    ensure
      session.database.close
      FileUtils.rm_rf(directory)
    end
  end

  # Runs every statement of *sql* and returns the last one's rows.
  def self.rows(session : Grant::SQLiteEngine::Query::Session, sql : String) : Array(Array(V))
    rows = [] of Array(V)
    SQLiteSQLOracle.split_statements(sql).each do |statement|
      next if statement.strip.empty?
      rows = [] of Array(V)
      query = session.prepare(statement)
      while query.step
        rows << query.row.dup
      end
    end
    rows
  end

  # The message of the error the statement fails with, or nil.
  def self.error(session : Grant::SQLiteEngine::Query::Session, sql : String) : String?
    rows(session, sql)
    nil
  rescue error : Grant::SQLiteEngine::SQLError
    error.message
  end

  # *list* as engine rows.
  def self.values(list : Array(Array(T))) : Array(Array(V)) forall T
    list.map { |row| row.map { |value| value.as(V) } }
  end

  CORPUS = File.expand_path("../corpus/trigger_scenarios.sql", __DIR__)
end

describe "Grant::SQLiteEngine::Query triggers" do
  describe "CREATE TRIGGER" do
    it "stores the trigger in sqlite_schema as C does, from its name through END" do
      TriggersSpecFixture.with_session do |session|
        TriggersSpecFixture.rows(session, <<-SQL)
          CREATE TABLE t(id INTEGER PRIMARY KEY, a);
          CREATE TRIGGER IF NOT EXISTS main.t_touch  AFTER UPDATE ON t FOR EACH ROW BEGIN
            UPDATE t SET a = 1 WHERE id = NEW.id;
          END;
          SQL
        TriggersSpecFixture.rows(session, "SELECT type, name, tbl_name, rootpage, sql FROM sqlite_master WHERE type = 'trigger'")
          .should eq([["trigger", "t_touch", "t", 0_i64,
                       "CREATE TRIGGER t_touch  AFTER UPDATE ON t FOR EACH ROW BEGIN\n  UPDATE t SET a = 1 WHERE id = NEW.id;\nEND"] of TriggersSpecFixture::V])
      end
    end

    it "reports C's errors for a duplicate name, a missing table and a trigger of the wrong kind" do
      TriggersSpecFixture.with_session do |session|
        TriggersSpecFixture.rows(session, "CREATE TABLE t(a); CREATE VIEW v AS SELECT a FROM t; CREATE TRIGGER x AFTER INSERT ON t BEGIN SELECT 1; END")
        TriggersSpecFixture.error(session, "CREATE TRIGGER x AFTER INSERT ON t BEGIN SELECT 1; END").should eq("trigger x already exists")
        TriggersSpecFixture.error(session, "CREATE TRIGGER IF NOT EXISTS x AFTER INSERT ON t BEGIN SELECT 1; END").should be_nil
        TriggersSpecFixture.error(session, "CREATE TRIGGER y AFTER INSERT ON nope BEGIN SELECT 1; END").should eq("no such table: main.nope")
        TriggersSpecFixture.error(session, "CREATE TRIGGER y BEFORE INSERT ON v BEGIN SELECT 1; END").should eq("cannot create BEFORE trigger on view: v")
        TriggersSpecFixture.error(session, "CREATE TRIGGER y INSTEAD OF INSERT ON t BEGIN SELECT 1; END").should eq("cannot create INSTEAD OF trigger on table: t")
        TriggersSpecFixture.error(session, "CREATE TRIGGER y AFTER INSERT ON t BEGIN SELECT ?; END").should eq("trigger cannot use variables")
        TriggersSpecFixture.error(session, "SELECT RAISE(ABORT, 'x')").should eq("RAISE() may only be used within a trigger-program")
      end
    end
  end

  describe "DROP TRIGGER" do
    it "drops a trigger, and DROP TABLE drops the table's triggers" do
      TriggersSpecFixture.with_session do |session|
        TriggersSpecFixture.rows(session, <<-SQL)
          CREATE TABLE t(a);
          CREATE TABLE u(b);
          CREATE TRIGGER t1 AFTER INSERT ON t BEGIN SELECT 1; END;
          CREATE TRIGGER t2 AFTER INSERT ON t BEGIN SELECT 1; END;
          CREATE TRIGGER u1 AFTER INSERT ON u BEGIN SELECT 1; END;
          DROP TRIGGER t1;
          DROP TRIGGER IF EXISTS t1;
          SQL
        TriggersSpecFixture.error(session, "DROP TRIGGER t1").should eq("no such trigger: t1")
        TriggersSpecFixture.rows(session, "DROP TABLE t; SELECT name FROM sqlite_master WHERE type = 'trigger'")
          .should eq([["u1"] of TriggersSpecFixture::V])
      end
    end
  end

  describe "firing" do
    it "touches updated_at after an update, with recursive_triggers off" do
      TriggersSpecFixture.with_session do |session|
        TriggersSpecFixture.rows(session, <<-SQL).should eq(TriggersSpecFixture.values([[1_i64, "b", "touched"], [2_i64, "c", nil]]))
          CREATE TABLE posts(id INTEGER PRIMARY KEY, title TEXT, updated_at TEXT);
          CREATE TRIGGER posts_touch AFTER UPDATE ON posts BEGIN
            UPDATE posts SET updated_at = 'touched' WHERE id = NEW.id;
          END;
          INSERT INTO posts(title) VALUES ('a'), ('c');
          UPDATE posts SET title = 'b' WHERE id = 1;
          SELECT * FROM posts ORDER BY id;
          SQL
      end
    end

    it "writes an audit row for each insert, update and delete, counting trigger rows only in total_changes()" do
      TriggersSpecFixture.with_session do |session|
        TriggersSpecFixture.rows(session, <<-SQL)
          CREATE TABLE accounts(id INTEGER PRIMARY KEY, balance REAL);
          CREATE TABLE audit(action TEXT, account_id, old_balance, new_balance);
          CREATE TRIGGER ai AFTER INSERT ON accounts BEGIN INSERT INTO audit VALUES ('insert', NEW.id, NULL, NEW.balance); END;
          CREATE TRIGGER au AFTER UPDATE OF balance ON accounts BEGIN INSERT INTO audit VALUES ('update', OLD.id, OLD.balance, NEW.balance); END;
          CREATE TRIGGER ad AFTER DELETE ON accounts BEGIN INSERT INTO audit VALUES ('delete', OLD.id, OLD.balance, NULL); END;
          INSERT INTO accounts(balance) VALUES (10), (20);
          SQL
        session.changes.should eq(2)
        session.total_changes.should eq(4)
        TriggersSpecFixture.rows(session, "UPDATE accounts SET balance = balance + 1 WHERE id = 1; DELETE FROM accounts WHERE id = 2")
        TriggersSpecFixture.rows(session, "SELECT * FROM audit ORDER BY rowid").should eq(TriggersSpecFixture.values([
          ["insert", 1_i64, nil, 10.0], ["insert", 2_i64, nil, 20.0], ["update", 1_i64, 10.0, 11.0], ["delete", 2_i64, 20.0, nil],
        ]))
      end
    end

    it "guards a soft delete with RAISE(ABORT) and skips rows with RAISE(IGNORE)" do
      TriggersSpecFixture.with_session do |session|
        TriggersSpecFixture.rows(session, <<-SQL)
          CREATE TABLE documents(id INTEGER PRIMARY KEY, deleted_at TEXT);
          CREATE TRIGGER guard BEFORE DELETE ON documents WHEN OLD.deleted_at IS NULL BEGIN
            SELECT RAISE(ABORT, 'soft delete documents instead');
          END;
          CREATE TRIGGER skip BEFORE INSERT ON documents WHEN NEW.deleted_at = 'skip' BEGIN SELECT RAISE(IGNORE); END;
          INSERT INTO documents(deleted_at) VALUES (NULL), ('skip'), ('2026');
          SQL
        TriggersSpecFixture.error(session, "DELETE FROM documents").should eq("soft delete documents instead")
        TriggersSpecFixture.rows(session, "SELECT id FROM documents ORDER BY id").should eq(TriggersSpecFixture.values([[1_i64], [2_i64]]))
        TriggersSpecFixture.rows(session, "DELETE FROM documents WHERE deleted_at IS NOT NULL; SELECT id FROM documents")
          .should eq(TriggersSpecFixture.values([[1_i64]]))
      end
    end

    it "runs INSTEAD OF triggers for writes to a view" do
      TriggersSpecFixture.with_session do |session|
        TriggersSpecFixture.rows(session, <<-SQL).should eq(TriggersSpecFixture.values([[1_i64, "Ada Byron"]]))
          CREATE TABLE people(id INTEGER PRIMARY KEY, first_name TEXT, last_name TEXT);
          CREATE VIEW names AS SELECT id, first_name || ' ' || last_name AS full_name, first_name, last_name FROM people;
          CREATE TRIGGER names_insert INSTEAD OF INSERT ON names BEGIN
            INSERT INTO people(first_name, last_name) VALUES (NEW.first_name, NEW.last_name);
          END;
          CREATE TRIGGER names_update INSTEAD OF UPDATE ON names BEGIN
            UPDATE people SET last_name = NEW.last_name WHERE id = OLD.id;
          END;
          INSERT INTO names(first_name, last_name) VALUES ('Ada', 'Lovelace');
          UPDATE names SET last_name = 'Byron';
          SELECT id, full_name FROM names;
          SQL
        session.changes.should eq(0)
      end
    end

    it "gives NEW.rowid -1 before an INSERT that picks the rowid, and the rowid after it" do
      TriggersSpecFixture.with_session do |session|
        TriggersSpecFixture.rows(session, <<-SQL).should eq(TriggersSpecFixture.values([["before", -1_i64], ["after", 1_i64]]))
          CREATE TABLE t(id INTEGER PRIMARY KEY, a);
          CREATE TABLE log(moment, rowid_seen);
          CREATE TRIGGER b BEFORE INSERT ON t BEGIN INSERT INTO log VALUES ('before', NEW.id); END;
          CREATE TRIGGER a AFTER INSERT ON t BEGIN INSERT INTO log VALUES ('after', NEW.rowid); END;
          INSERT INTO t(a) VALUES ('x');
          SELECT * FROM log ORDER BY rowid;
          SQL
        session.last_insert_rowid.should eq(1)
      end
    end
  end

  describe "against C SQLite 3.51.0" do
    linked = SQLiteSQLOracle.version.split(' ').first
    if linked == "3.51.0"
      it "matches C on every scenario of the trigger corpus" do
        report = TriggerReport.new
        work = File.join(Dir.tempdir, "grant-trigger-corpus-#{Random::Secure.hex(6)}")
        begin
          differential = TriggerDifferential.new(report, work)
          TriggerScenarios.from_corpus(TriggersSpecFixture::CORPUS).each { |scenario| differential.run(scenario) }
        ensure
          FileUtils.rm_rf(work)
        end
        report.list_of_differences.should eq([] of String)
        report.counts["statements matching C"].should be > 300
      end
    else
      pending "matches C on every scenario of the trigger corpus (the linked libsqlite3 is #{linked})"
    end
  end
end
