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
