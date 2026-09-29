require "../../spec_helper"

alias G01Kind = Grant::Adapter::ErrorTranslator::Kind

private def pg_error(sqlstate : String, message : String = "ERROR: something failed") : PQ::PQError
  PQ::PQError.new([
    PQ::Frame::ErrorResponse::Field.new(:code, sqlstate, 'C'.ord.to_u8),
    PQ::Frame::ErrorResponse::Field.new(:message, message, 'M'.ord.to_u8),
  ])
end

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class G01Account < Grant::Base
    connection {{ adapter_literal }}
    table g01_accounts

    column id : Int64, primary: true
    column email : String
    column code : String?
  end

  class G01Note < Grant::Base
    connection {{ adapter_literal }}
    table g01_notes

    column id : Int64, primary: true
    column account_id : Int64?
    column body : String?
  end
{% end %}

private def create_g01_tables
  adapter = G01Account.adapter
  statements = if adapter.postgres?
                 [
                   "DROP TABLE IF EXISTS g01_notes", "DROP TABLE IF EXISTS g01_accounts",
                   "CREATE TABLE g01_accounts (id BIGSERIAL PRIMARY KEY, email VARCHAR(40) NOT NULL UNIQUE, code VARCHAR(5))",
                   "CREATE TABLE g01_notes (id BIGSERIAL PRIMARY KEY, account_id BIGINT REFERENCES g01_accounts(id), body TEXT NOT NULL DEFAULT '')",
                 ]
               elsif adapter.mysql?
                 [
                   "DROP TABLE IF EXISTS g01_notes", "DROP TABLE IF EXISTS g01_accounts",
                   "CREATE TABLE g01_accounts (id BIGINT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(40) NOT NULL UNIQUE, code VARCHAR(5))",
                   "CREATE TABLE g01_notes (id BIGINT AUTO_INCREMENT PRIMARY KEY, account_id BIGINT, body TEXT, FOREIGN KEY (account_id) REFERENCES g01_accounts(id))",
                 ]
               else
                 [
                   "DROP TABLE IF EXISTS g01_notes", "DROP TABLE IF EXISTS g01_accounts",
                   "CREATE TABLE g01_accounts (id INTEGER PRIMARY KEY, email VARCHAR(40) NOT NULL UNIQUE, code VARCHAR(5))",
                   "CREATE TABLE g01_notes (id INTEGER PRIMARY KEY, account_id INTEGER REFERENCES g01_accounts(id), body TEXT NOT NULL DEFAULT '')",
                 ]
               end
  statements.each { |statement| adapter.open { |db| db.exec statement } }
end

describe "Grant constraint and lock error translation" do
  describe "PostgreSQL SQLSTATE classification" do
    {
      "23505" => G01Kind::Unique,
      "23503" => G01Kind::ForeignKey,
      "23502" => G01Kind::NotNull,
      "22001" => G01Kind::ValueTooLong,
      "40P01" => G01Kind::Deadlock,
      "40001" => G01Kind::SerializationFailure,
      "55P03" => G01Kind::LockWaitTimeout,
      "57014" => G01Kind::QueryCanceled,
      "25006" => G01Kind::ReadOnly,
      "3D000" => G01Kind::NoDatabase,
    }.each do |state, kind|
      it "maps #{state} to #{kind}" do
        Grant::Adapter::Pg.error_kind(state).should eq(kind)
      end
    end

    it "separates a statement timeout from a user cancel on 57014" do
      Grant::Adapter::Pg.error_kind("57014", "canceling statement due to statement timeout")
        .should eq(G01Kind::StatementTimeout)
      Grant::Adapter::Pg.error_kind("57014", "canceling statement due to user request")
        .should eq(G01Kind::QueryCanceled)
    end

    it "does not translate other codes" do
      Grant::Adapter::Pg.error_kind("42P01").should be_nil
      Grant::Adapter::Pg.error_kind(nil).should be_nil
    end
  end

  describe "MySQL errno classification" do
    {
      1062 => G01Kind::Unique,
      1452 => G01Kind::ForeignKey,
      1451 => G01Kind::ForeignKey,
      1048 => G01Kind::NotNull,
      1406 => G01Kind::ValueTooLong,
      1213 => G01Kind::Deadlock,
      1205 => G01Kind::LockWaitTimeout,
      3572 => G01Kind::LockWaitTimeout,
      3024 => G01Kind::StatementTimeout,
      1317 => G01Kind::QueryCanceled,
      1792 => G01Kind::ReadOnly,
      1049 => G01Kind::NoDatabase,
    }.each do |errno, kind|
      it "maps errno #{errno} to #{kind}" do
        Grant::Adapter::Mysql.error_kind(errno).should eq(kind)
      end
    end

    it "does not translate other numbers" do
      Grant::Adapter::Mysql.error_kind(1064).should be_nil
      Grant::Adapter::Mysql.error_kind(nil).should be_nil
    end

    it "recovers the errno from the server message because crystal-mysql drops the code" do
      {
        "Duplicate entry 'a@b.c' for key 'g01_accounts.email'"                                             => 1062,
        "Cannot add or update a child row: a foreign key constraint fails (`db`.`n`, CONSTRAINT `fk`)"     => 1452,
        "Cannot delete or update a parent row: a foreign key constraint fails (`db`.`n`, CONSTRAINT `fk`)" => 1451,
        "Column 'email' cannot be null"                                                                    => 1048,
        "Field 'email' doesn't have a default value"                                                       => 1364,
        "Data too long for column 'code' at row 1"                                                         => 1406,
        "Deadlock found when trying to get lock; try restarting transaction"                               => 1213,
        "Lock wait timeout exceeded; try restarting transaction"                                           => 1205,
        "Statement aborted because lock(s) could not be acquired immediately and NOWAIT is set."           => 3572,
        "Query execution was interrupted, maximum statement execution time exceeded"                       => 3024,
        "Query execution was interrupted"                                                                  => 1317,
        "Cannot execute statement in a READ ONLY transaction."                                             => 1792,
        "Unknown database 'nope'"                                                                          => 1049,
      }.each do |message, errno|
        Grant::Adapter::Mysql.errno_for_message(message).should eq(errno)
      end
      Grant::Adapter::Mysql.errno_for_message("You have an error in your SQL syntax").should be_nil
      Grant::Adapter::Mysql.errno_for_message(nil).should be_nil
    end
  end

  describe "SQLite result code classification" do
    it "classifies constraints by their message" do
      Grant::Adapter::Sqlite.error_kind(19, "UNIQUE constraint failed: t.email").should eq(G01Kind::Unique)
      Grant::Adapter::Sqlite.error_kind(19, "FOREIGN KEY constraint failed").should eq(G01Kind::ForeignKey)
      Grant::Adapter::Sqlite.error_kind(19, "NOT NULL constraint failed: t.email").should eq(G01Kind::NotNull)
      Grant::Adapter::Sqlite.error_kind(19, "CHECK constraint failed: positive").should be_nil
    end

    it "classifies extended constraint codes without the message" do
      Grant::Adapter::Sqlite.error_kind(2067).should eq(G01Kind::Unique)
      Grant::Adapter::Sqlite.error_kind(1555).should eq(G01Kind::Unique)
      Grant::Adapter::Sqlite.error_kind(787).should eq(G01Kind::ForeignKey)
      Grant::Adapter::Sqlite.error_kind(1299).should eq(G01Kind::NotNull)
    end

    it "classifies the non-constraint result codes" do
      Grant::Adapter::Sqlite.error_kind(5, "database is locked").should eq(G01Kind::LockWaitTimeout)
      Grant::Adapter::Sqlite.error_kind(6, "database table is locked").should eq(G01Kind::LockWaitTimeout)
      Grant::Adapter::Sqlite.error_kind(517).should eq(G01Kind::LockWaitTimeout)
      Grant::Adapter::Sqlite.error_kind(8, "attempt to write a readonly database").should eq(G01Kind::ReadOnly)
      Grant::Adapter::Sqlite.error_kind(9, "interrupted").should eq(G01Kind::QueryCanceled)
      Grant::Adapter::Sqlite.error_kind(14, "unable to open database file").should eq(G01Kind::NoDatabase)
      Grant::Adapter::Sqlite.error_kind(18, "string or blob too big").should eq(G01Kind::ValueTooLong)
      Grant::Adapter::Sqlite.error_kind(1, "SQL logic error").should be_nil
      Grant::Adapter::Sqlite.error_kind(nil).should be_nil
    end
  end

  describe "#translate_exception outside a transaction" do
    pg = Grant::Adapter::Pg.new(name: "g01_pg_translate", url: "postgres://localhost/unused")
    mysql = Grant::Adapter::Mysql.new(name: "g01_mysql_translate", url: "mysql://localhost/unused")

    {
      {"23505", Grant::RecordNotUnique},
      {"23503", Grant::InvalidForeignKey},
      {"23502", Grant::NotNullViolation},
      {"22001", Grant::ValueTooLong},
      {"40P01", Grant::Deadlocked},
      {"40001", Grant::SerializationFailure},
      {"55P03", Grant::LockWaitTimeout},
      {"57014", Grant::QueryCanceled},
      {"3D000", Grant::NoDatabaseError},
    }.each do |(state, error_class)|
      it "turns PostgreSQL #{state} into #{error_class}" do
        driver_error = pg_error(state)
        translated = pg.translate_exception(driver_error, "SELECT 1", [1])

        (translated.class <= error_class).should be_true
        translated.should be_a(Grant::StatementInvalid)
        translated.message.should eq(driver_error.message)
        translated.cause.should be(driver_error)
        translated.as(Grant::StatementInvalid).sql.should eq("SELECT 1")
      end
    end

    it "groups deadlocks and serialization failures under TransactionRollbackError" do
      pg.translate_exception(pg_error("40P01")).should be_a(Grant::TransactionRollbackError)
      pg.translate_exception(pg_error("40001")).should be_a(Grant::TransactionRollbackError)
    end

    it "turns a read-only transaction into ReadOnlyError" do
      pg.translate_exception(pg_error("25006")).should be_a(Grant::ReadOnlyError)
    end

    it "wraps an unclassified PostgreSQL error as StatementInvalid" do
      translated = pg.translate_exception(pg_error("42P01"))
      translated.class.should eq(Grant::StatementInvalid)
    end

    it "turns MySQL server errors into the taxonomy by message" do
      packet_error = MySql::Connection::PacketError.new("Deadlock found when trying to get lock; try restarting transaction")
      translated = mysql.translate_exception(packet_error, "UPDATE t SET a = 1")
      translated.should be_a(Grant::Deadlocked)
      translated.cause.should be(packet_error)
    end

    it "wraps an unclassified MySQL error as StatementInvalid" do
      mysql.translate_exception(MySql::Connection::PacketError.new("syntax error")).class.should eq(Grant::StatementInvalid)
    end

    it "returns exceptions it does not recognize unchanged" do
      rollback = Grant::Transaction::Rollback.new
      pg.translate_exception(rollback).should be(rollback)
      mysql.translate_exception(rollback).should be(rollback)

      plain = DB::Error.new("plain")
      pg.translate_exception(plain).should be(plain)
    end

    it "maps crystal-db pool failures for every adapter" do
      pg.translate_exception(DB::PoolTimeout.new("checkout")).should be_a(Grant::ConnectionTimeoutError)
      pg.translate_exception(DB::ConnectionRefused.new).should be_a(Grant::ConnectionFailed)
      mysql.translate_exception(DB::PoolRetryAttemptsExceeded.new).should be_a(Grant::ConnectionFailed)
    end
  end

  describe "on the #{CURRENT_ADAPTER} adapter" do
    before_each do
      create_g01_tables
    end

    it "raises RecordNotUnique for a duplicate key" do
      G01Account.adapter.open { |db| db.exec "INSERT INTO g01_accounts (email) VALUES ('a@example.com')" }

      error = expect_raises(Grant::RecordNotUnique) do
        G01Account.adapter.open("INSERT INTO g01_accounts (email) VALUES (?)", ["a@example.com"]) do |db|
          db.exec G01Account.adapter.ensure_clause_template("INSERT INTO g01_accounts (email) VALUES (?)"), "a@example.com"
        end
      end
      error.should be_a(Grant::StatementInvalid)
      error.cause.should_not be_nil
    end

    it "raises RecordNotUnique through the adapter's insert" do
      G01Account.create!(email: "dup@example.com")
      expect_raises(Grant::RecordNotUnique) do
        G01Account.adapter.insert("g01_accounts", ["email"], ["dup@example.com"] of Grant::Columns::Type, lastval: nil)
      end
    end

    it "raises InvalidForeignKey for a missing parent" do
      expect_raises(Grant::InvalidForeignKey) do
        G01Note.adapter.insert("g01_notes", ["account_id"], [999_i64] of Grant::Columns::Type, lastval: nil)
      end
    end

    it "raises InvalidForeignKey when deleting a referenced parent" do
      account = G01Account.create!(email: "parent@example.com")
      G01Note.create!(account_id: account.id, body: "child")

      expect_raises(Grant::InvalidForeignKey) do
        G01Account.adapter.delete("g01_accounts", "id", account.id)
      end
    end

    it "raises NotNullViolation for a NULL in a NOT NULL column" do
      expect_raises(Grant::NotNullViolation) do
        G01Account.adapter.open("INSERT INTO g01_accounts (email) VALUES (NULL)") do |db|
          db.exec "INSERT INTO g01_accounts (email) VALUES (NULL)"
        end
      end
    end

    it "raises ValueTooLong for a value over the column length" do
      if G01Account.adapter.sqlite?
        pending!("SQLite does not enforce VARCHAR length; its TOOBIG code is covered above")
      end

      expect_raises(Grant::ValueTooLong) do
        G01Account.adapter.insert("g01_accounts", ["email", "code"], ["long@example.com", "far too long"] of Grant::Columns::Type, lastval: nil)
      end
    end

    it "translates errors raised inside a transaction block" do
      G01Account.create!(email: "tx@example.com")

      expect_raises(Grant::RecordNotUnique) do
        G01Account.transaction do
          G01Account.adapter.insert("g01_accounts", ["email"], ["tx@example.com"] of Grant::Columns::Type, lastval: nil)
        end
      end
      G01Account.count.should eq(1)
    end

    it "exposes the translated error on RecordNotSaved from create!" do
      G01Account.create!(email: "same@example.com")

      error = expect_raises(Grant::RecordNotSaved) do
        G01Account.create!(email: "same@example.com")
      end
      error.should_not be_a(Grant::RecordInvalid)
      error.statement_error.should be_a(Grant::RecordNotUnique)
    end

    it "keeps save returning false with the driver message on the record" do
      G01Account.create!(email: "same@example.com")

      duplicate = G01Account.new(email: "same@example.com")
      duplicate.save.should be_false
      duplicate.errors.empty?.should be_false
    end

    it "reports a foreign key failure from save! as RecordNotSaved with an InvalidForeignKey cause" do
      note = G01Note.new(account_id: 424242_i64, body: "orphan")
      error = expect_raises(Grant::RecordNotSaved) { note.save! }
      error.statement_error.should be_a(Grant::InvalidForeignKey)
    end
  end

  describe "pool checkout on the #{CURRENT_ADAPTER} adapter" do
    it "raises ConnectionTimeoutError when no connection frees up in time" do
      separator = ADAPTER_URL.includes?('?') ? '&' : '?'
      url = "#{ADAPTER_URL}#{separator}max_pool_size=1&checkout_timeout=0.2"
      adapter = G01Account.adapter.class.new(name: "g01_pool_timeout", url: url)

      begin
        adapter.database.using_connection do |_held|
          error = expect_raises(Grant::ConnectionTimeoutError) do
            adapter.open("SELECT 1") { |db| db.scalar("SELECT 1") }
          end
          error.should be_a(Grant::ConnectionNotEstablished)
          error.cause.should be_a(DB::PoolTimeout)
        end
      ensure
        adapter.database.close
      end
    end
  end

  describe "PostgreSQL server errors" do
    it "maps deadlock, serialization, lock, cancel and read-only failures raised by the server" do
      unless G01Account.adapter.postgres?
        pending!("PostgreSQL only")
      end

      adapter = G01Account.adapter
      {
        "40P01" => Grant::Deadlocked,
        "40001" => Grant::SerializationFailure,
        "55P03" => Grant::LockWaitTimeout,
        "57014" => Grant::QueryCanceled,
        "25006" => Grant::ReadOnlyError,
      }.each do |state, error_class|
        statement = "DO $$ BEGIN RAISE EXCEPTION 'g01 test' USING ERRCODE = '#{state}'; END $$"
        raised = begin
          adapter.open(statement) { |db| db.exec statement }
          nil
        rescue ex
          ex
        end

        raised.should_not be_nil
        (raised.not_nil!.class <= error_class).should be_true
      end
    end

    it "maps a real deadlock between two connections outside Model.transaction" do
      unless G01Account.adapter.postgres?
        pending!("PostgreSQL only")
      end
      create_g01_tables
      adapter = G01Account.adapter
      first_id = G01Account.create!(email: "d1@example.com").id
      second_id = G01Account.create!(email: "d2@example.com").id

      results = Channel(Exception?).new(2)
      ready = Channel(Nil).new(2)
      proceed = Channel(Nil).new(2)

      spawn do
        outcome = begin
          adapter.open_pool_connection("UPDATE g01_accounts") do |conn|
            conn.exec "BEGIN"
            conn.exec "UPDATE g01_accounts SET code = 'a' WHERE id = #{first_id}"
            ready.send(nil)
            proceed.receive
            begin
              conn.exec "UPDATE g01_accounts SET code = 'a' WHERE id = #{second_id}"
              conn.exec "COMMIT"
            rescue ex
              conn.exec "ROLLBACK"
              raise ex
            end
          end
          nil
        rescue ex
          ex
        end
        results.send(outcome)
      end

      spawn do
        outcome = begin
          adapter.open_pool_connection("UPDATE g01_accounts") do |conn|
            conn.exec "BEGIN"
            conn.exec "UPDATE g01_accounts SET code = 'b' WHERE id = #{second_id}"
            ready.send(nil)
            proceed.receive
            begin
              conn.exec "UPDATE g01_accounts SET code = 'b' WHERE id = #{first_id}"
              conn.exec "COMMIT"
            rescue ex
              conn.exec "ROLLBACK"
              raise ex
            end
          end
          nil
        rescue ex
          ex
        end
        results.send(outcome)
      end

      2.times { ready.receive }
      2.times { proceed.send(nil) }
      outcomes = [results.receive, results.receive]

      outcomes.compact.any?(Grant::Deadlocked).should be_true
    end

    it "raises StatementTimeout when the server's statement_timeout expires" do
      unless G01Account.adapter.postgres?
        pending!("PostgreSQL only")
      end

      error = expect_raises(Grant::StatementTimeout) do
        G01Account.adapter.open_pool_connection("SELECT pg_sleep(2)") do |conn|
          conn.exec "SET statement_timeout = 50"
          begin
            conn.exec "SELECT pg_sleep(2)"
          ensure
            conn.exec "RESET statement_timeout"
          end
        end
      end
      error.cause.should be_a(PQ::PQError)
    end

    it "raises QueryCanceled when another session cancels the statement" do
      unless G01Account.adapter.postgres?
        pending!("PostgreSQL only")
      end
      adapter = G01Account.adapter

      error = expect_raises(Grant::QueryCanceled) do
        adapter.open_pool_connection("SELECT pg_sleep(5)") do |conn|
          backend_pid = conn.scalar("SELECT pg_backend_pid()").as(Int32)
          spawn do
            sleep 200.milliseconds
            adapter.database.using_connection do |other|
              other.exec "SELECT pg_cancel_backend($1)", backend_pid
            end
          end
          conn.exec "SELECT pg_sleep(5)"
        end
      end
      error.should_not be_a(Grant::StatementTimeout)
    end

    it "raises LockWaitTimeout for a NOWAIT lock on a row another session holds" do
      unless G01Account.adapter.postgres?
        pending!("PostgreSQL only")
      end
      create_g01_tables
      adapter = G01Account.adapter
      account_id = G01Account.create!(email: "locked@example.com").id

      locked = Channel(Nil).new
      release = Channel(Nil).new
      finished = Channel(Nil).new
      spawn do
        adapter.database.using_connection do |conn|
          conn.exec "BEGIN"
          conn.exec "SELECT id FROM g01_accounts WHERE id = #{account_id} FOR UPDATE"
          locked.send(nil)
          release.receive
          conn.exec "ROLLBACK"
        end
        finished.send(nil)
      end

      locked.receive
      begin
        error = expect_raises(Grant::LockWaitTimeout) do
          G01Account.where(id: account_id).lock(Grant::Locking::LockMode::UpdateNoWait).to_a
        end
        error.should be_a(Grant::Locking::LockWaitTimeoutError)
      ensure
        release.send(nil)
        finished.receive
      end
    end
  end

  describe "SQLite server errors" do
    it "raises LockWaitTimeout when another connection holds the write lock" do
      unless G01Account.adapter.sqlite?
        pending!("SQLite only")
      end

      path = File.tempname("g01_busy", ".sqlite3")
      adapter = Grant::Adapter::Sqlite.new(name: "g01_busy", url: "sqlite3:#{path}?busy_timeout=0")
      begin
        adapter.open { |db| db.exec "CREATE TABLE busy_rows (id INTEGER PRIMARY KEY)" }
        adapter.database.using_connection do |holder|
          holder.exec "BEGIN IMMEDIATE"
          begin
            statement = "INSERT INTO busy_rows (id) VALUES (1)"
            error = expect_raises(Grant::LockWaitTimeout) do
              adapter.open_pool_connection(statement) { |db| db.exec statement }
            end
            error.cause.should be_a(SQLite3::Exception)
          ensure
            holder.exec "ROLLBACK"
          end
        end
      ensure
        adapter.database.close
        {path, "#{path}-wal", "#{path}-shm"}.each { |file| File.delete?(file) }
      end
    end
  end
end
