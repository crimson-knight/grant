require "../spec_helper"
require "../../src/grant/spec_support/*"

private def adapter : Grant::Adapter::Base
  Parent.adapter
end

private def serial_key : String
  if adapter.postgres?
    "BIGSERIAL PRIMARY KEY"
  elsif adapter.mysql?
    "BIGINT AUTO_INCREMENT PRIMARY KEY"
  else
    "INTEGER PRIMARY KEY AUTOINCREMENT"
  end
end

private def run(statement : String) : Nil
  adapter.open(&.exec(statement))
end

private def count(table : String) : Int64
  adapter.open(&.scalar("SELECT COUNT(*) FROM #{table}")).to_s.to_i64
end

private def insert_author(name : String) : Int64
  run "INSERT INTO o01_authors (name) VALUES ('#{name}')"
  adapter.open(&.scalar("SELECT MAX(id) FROM o01_authors")).to_s.to_i64
end

describe "Adapter test helpers" do
  before_all do
    run "DROP TABLE IF EXISTS o01_books"
    run "DROP TABLE IF EXISTS o01_authors"
    run "CREATE TABLE o01_authors (id #{serial_key}, name VARCHAR(50))"
    # A table-level FOREIGN KEY clause: MySQL 8.0 parses and ignores an
    # inline column REFERENCES clause.
    run "CREATE TABLE o01_books (id #{serial_key}, author_id BIGINT NOT NULL, title VARCHAR(50), FOREIGN KEY (author_id) REFERENCES o01_authors (id))"
  end

  after_all do
    run "DROP TABLE IF EXISTS o01_books"
    run "DROP TABLE IF EXISTS o01_authors"
  end

  before_each do
    adapter.truncate_tables("o01_books", "o01_authors")
  end

  describe "#truncate_tables" do
    it "empties several tables in one call and restarts their ids" do
      3.times { |index| insert_author("a#{index}") }
      run "INSERT INTO o01_books (author_id, title) VALUES (1, 'b')"

      adapter.truncate_tables("o01_books", "o01_authors")

      count("o01_books").should eq(0)
      count("o01_authors").should eq(0)
      insert_author("fresh").should eq(1)
    end

    it "is a single TRUNCATE ... RESTART IDENTITY CASCADE on PostgreSQL" do
      statements = Grant::Spec.capture_queries { adapter.truncate_tables("o01_books", "o01_authors") }.map(&.sql)

      if adapter.postgres?
        statements.size.should eq(1)
        statements.first.should contain("TRUNCATE TABLE")
        statements.first.should contain("RESTART IDENTITY CASCADE")
      else
        statements.size.should be >= 2
      end
    end

    it "does nothing for an empty list" do
      insert_author("kept")
      adapter.truncate_tables([] of String)
      count("o01_authors").should eq(1)
    end
  end

  describe "#reset_pk_sequence!" do
    it "moves the counter back to one past the highest id" do
      3.times { |index| insert_author("a#{index}") }
      run "DELETE FROM o01_authors WHERE id > 1"

      adapter.reset_pk_sequence!("o01_authors")

      insert_author("next").should eq(2)
    end

    it "moves the counter past rows loaded with explicit ids" do
      run "INSERT INTO o01_authors (id, name) VALUES (50, 'explicit')"

      adapter.reset_pk_sequence!("o01_authors")

      insert_author("after").should eq(51)
    end

    it "restarts at 1 for an empty table" do
      2.times { |index| insert_author("a#{index}") }
      run "DELETE FROM o01_authors"

      adapter.reset_pk_sequence!("o01_authors")

      insert_author("first").should eq(1)
    end
  end

  describe "#disable_referential_integrity" do
    it "allows a child row before its parent exists" do
      adapter.disable_referential_integrity do
        run "INSERT INTO o01_books (author_id, title) VALUES (77, 'early')"
        run "INSERT INTO o01_authors (id, name) VALUES (77, 'late')"
      end

      count("o01_books").should eq(1)
      count("o01_authors").should eq(1)
    end

    it "returns the block's value" do
      adapter.disable_referential_integrity { 42 }.should eq(42)
    end

    it "enforces foreign keys again after the block" do
      adapter.disable_referential_integrity { }

      expect_raises(Grant::InvalidForeignKey) do
        run "INSERT INTO o01_books (author_id, title) VALUES (999, 'orphan')"
      end
    end

    it "enforces foreign keys again after the block raised" do
      expect_raises(Exception, "in block") do
        adapter.disable_referential_integrity { raise "in block" }
      end

      expect_raises(Grant::InvalidForeignKey) do
        run "INSERT INTO o01_books (author_id, title) VALUES (999, 'orphan')"
      end
    end

    it "joins an open transaction and undoes its work with it" do
      Parent.transaction do
        adapter.disable_referential_integrity do
          run "INSERT INTO o01_books (author_id, title) VALUES (5, 'joined')"
          run "INSERT INTO o01_authors (id, name) VALUES (5, 'joined')"
        end
        raise Grant::Transaction::Rollback.new
      end

      count("o01_books").should eq(0)
    end
  end
end
