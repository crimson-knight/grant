require "spec"

{% skip_file unless (env("CURRENT_ADAPTER") || "sqlite") == "sqlite" %}

require "./upstream/spec_helper"

RESULT_SET_CLOSE_SPEC_FILENAME = "./result_set_close_spec.db"

# Opens two connections to one fresh database file (SQLite's default
# rollback journal, busy timeout 0) with an empty `numbers` table.
private def with_writer_and_reader(&block : DB::Connection, DB::Connection ->)
  File.delete(RESULT_SET_CLOSE_SPEC_FILENAME) rescue nil
  writer = DB.connect "sqlite3:#{RESULT_SET_CLOSE_SPEC_FILENAME}"
  reader = DB.connect "sqlite3:#{RESULT_SET_CLOSE_SPEC_FILENAME}"
  begin
    writer.exec "create table numbers (n integer)"
    block.call(writer, reader)
  ensure
    reader.close
    writer.close
    File.delete(RESULT_SET_CLOSE_SPEC_FILENAME) rescue nil
  end
end

# Inserts three rows with RETURNING and reads only the first, so closing
# the result set is what finishes the statement and commits the write.
private def insert_three_and_read_first(writer : DB::Connection) : Int64
  writer.query("insert into numbers (n) values (1), (2), (3) returning n") do |result_set|
    result_set.move_next
    result_set.read(Int64)
  end
end

describe Grant::SQLite3::ResultSet do
  it "raises a commit failure found while closing a partly read INSERT RETURNING" do
    with_writer_and_reader do |writer, reader|
      # The open read transaction holds a shared lock, so the writer's
      # commit at close cannot get the exclusive lock.
      reader.exec "begin"
      reader.scalar("select count(*) from numbers").should eq(0)

      result_set = writer.query("insert into numbers (n) values (1), (2), (3) returning n")
      result_set.move_next.should be_true

      expect_raises(Grant::SQLite3::Exception, "database is locked") do
        result_set.close
      end

      # The failed close still released the result set, and it says so.
      result_set.closed?.should be_true
      result_set.close

      reader.exec "rollback"
    end
  end

  it "retries its release on a later close after SQLite refused to close the released connection" do
    File.delete(RESULT_SET_CLOSE_SPEC_FILENAME) rescue nil
    open_descriptors_before = Dir.children("/dev/fd").size
    # With no idle slots, releasing the result set's connection closes it.
    db = DB.open "sqlite3:#{RESULT_SET_CLOSE_SPEC_FILENAME}?max_idle_pool_size=0"
    begin
      result_set = db.query "select 1"
      result_set.move_next.should be_true
      # Built directly, so the connection's statement cache does not hold it,
      # and SQLite refuses to close the connection while it is unfinalized.
      uncached_statement = Grant::SQLite3::Statement.new(result_set.statement.connection, "select 2")

      expect_raises(Grant::SQLite3::Exception, "unfinalized statements") do
        result_set.close
      end
      result_set.closed?.should be_false

      uncached_statement.close
      result_set.close

      result_set.closed?.should be_true
      # The retried release closed the connection and the pool let it go.
      db.pool.stats.open_connections.should eq(0)
      db.close
      Dir.children("/dev/fd").size.should eq(open_descriptors_before)
    ensure
      File.delete(RESULT_SET_CLOSE_SPEC_FILENAME) rescue nil
    end
  end

  it "commits a partly read INSERT RETURNING when no reader holds a lock" do
    with_writer_and_reader do |writer, reader|
      insert_three_and_read_first(writer).should eq(1)

      reader.scalar("select count(*) from numbers").should eq(3)
    end
  end

  it "raises a failed step once, from move_next, and closes without raising it again" do
    with_writer_and_reader do |writer, reader|
      writer.exec "create table capped_numbers (n integer check (n < 2))"

      expect_raises(Grant::SQLite3::Exception, "CHECK constraint failed") do
        writer.query("insert into capped_numbers (n) values (1), (2) returning n") do |result_set|
          result_set.move_next
        end
      end

      reader.scalar("select count(*) from capped_numbers").should eq(0)
    end
  end
end
