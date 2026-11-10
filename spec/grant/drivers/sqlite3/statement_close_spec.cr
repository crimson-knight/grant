require "spec"

{% skip_file unless (env("CURRENT_ADAPTER") || "sqlite") == "sqlite" %}

require "./upstream/spec_helper"

STATEMENT_CLOSE_SPEC_FILENAME = "./statement_close_spec.db"

# Opens a fresh database with a table that accepts n below 10, runs the
# block, then closes the database and returns whatever closing raised.
private def error_from_closing_after(&block : DB::Database ->) : Exception?
  File.delete(STATEMENT_CLOSE_SPEC_FILENAME) rescue nil
  db = DB.open "sqlite3:#{STATEMENT_CLOSE_SPEC_FILENAME}"
  closing_error : Exception? = nil
  begin
    db.exec "create table capped_numbers (n integer check (n < 10))"
    block.call(db)
  ensure
    closing_error = begin
      db.close
      nil
    rescue error : Exception
      error
    end
    File.delete(STATEMENT_CLOSE_SPEC_FILENAME) rescue nil
  end
  closing_error
end

private def insert_capped_number(db : DB::Database, number : Int32)
  db.exec "insert into capped_numbers (n) values (?)", number
end

describe Grant::SQLite3::Statement do
  it "closes the database without raising after a statement's last step failed" do
    closing_error = error_from_closing_after do |db|
      expect_raises(Grant::SQLite3::Exception, "CHECK constraint failed") do
        insert_capped_number(db, 10)
      end
    end

    closing_error.should be_nil
  end

  it "raises the failed step's error to the caller that ran the statement" do
    error_from_closing_after do |db|
      insert_capped_number(db, 9)

      expect_raises(Grant::SQLite3::Exception, "CHECK constraint failed") do
        insert_capped_number(db, 10)
      end

      db.scalar("select count(*) from capped_numbers").should eq(1)
    end
  end

  it "raises a failed write that SQLite first reports when the statement is finalized" do
    File.delete(STATEMENT_CLOSE_SPEC_FILENAME) rescue nil
    connection = DB.connect "sqlite3:#{STATEMENT_CLOSE_SPEC_FILENAME}?foreign_keys=1"
    begin
      connection.exec "create table parents (id integer primary key)"
      connection.exec "create table children (parent_id integer references parents (id) deferrable initially deferred)"

      # The deferred foreign key is checked at commit, which this partly
      # read statement reaches only when the connection finalizes it.
      result_set = connection.query "insert into children (parent_id) values (98), (99) returning parent_id"
      result_set.move_next.should be_true

      expect_raises(Grant::SQLite3::Exception, "FOREIGN KEY constraint failed") do
        connection.close
      end

      # The connection finished closing before it raised, and it says so.
      connection.closed?.should be_true
      connection.close
    ensure
      File.delete(STATEMENT_CLOSE_SPEC_FILENAME) rescue nil
    end
  end

  it "finishes closing the connection on a later close after SQLite refused while a statement was open" do
    File.delete(STATEMENT_CLOSE_SPEC_FILENAME) rescue nil
    open_descriptors_before = Dir.children("/dev/fd").size
    connection = DB.connect "sqlite3:#{STATEMENT_CLOSE_SPEC_FILENAME}"
    begin
      # Built directly, so the connection's statement cache does not hold it.
      uncached_statement = Grant::SQLite3::Statement.new(connection, "select 1")

      expect_raises(Grant::SQLite3::Exception, "unfinalized statements") do
        connection.close
      end
      connection.closed?.should be_false

      uncached_statement.close
      connection.close

      connection.closed?.should be_true
      # The SQLite handle released its file descriptor, so it really closed.
      Dir.children("/dev/fd").size.should eq(open_descriptors_before)
    ensure
      File.delete(STATEMENT_CLOSE_SPEC_FILENAME) rescue nil
    end
  end

  it "keeps a pooled connection that SQLite refused to close, so closing the database again finishes it" do
    File.delete(STATEMENT_CLOSE_SPEC_FILENAME) rescue nil
    open_descriptors_before = Dir.children("/dev/fd").size
    db = DB.open "sqlite3:#{STATEMENT_CLOSE_SPEC_FILENAME}"
    begin
      pooled_connection = db.checkout
      # Built directly, so the connection's statement cache does not hold it.
      uncached_statement = Grant::SQLite3::Statement.new(pooled_connection, "select 1")
      pooled_connection.release

      expect_raises(Grant::SQLite3::Exception, "unfinalized statements") do
        db.close
      end
      pooled_connection.closed?.should be_false

      uncached_statement.close
      db.close

      pooled_connection.closed?.should be_true
      Dir.children("/dev/fd").size.should eq(open_descriptors_before)
    ensure
      File.delete(STATEMENT_CLOSE_SPEC_FILENAME) rescue nil
    end
  end

  it "closes the database without raising after a failed step was followed by a successful one" do
    closing_error = error_from_closing_after do |db|
      expect_raises(Grant::SQLite3::Exception, "CHECK constraint failed") do
        insert_capped_number(db, 10)
      end
      insert_capped_number(db, 9)
    end

    closing_error.should be_nil
  end
end
