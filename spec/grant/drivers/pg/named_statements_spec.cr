require "spec"

{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "../../../../src/grant/drivers/pg/pg"

private ADMIN_URL = ENV["PG_DATABASE_URL"]? || "postgres:///"

# A database holding exactly one connection, so every statement in an example
# shares one server session and one `pg_prepared_statements` view.
private def with_one_connection(parameters : String = "", & : DB::Database ->)
  separator = ADMIN_URL.includes?("?") ? "&" : "?"
  query = "initial_pool_size=1&max_pool_size=1&max_idle_pool_size=1"
  query = "#{query}&#{parameters}" unless parameters.empty?
  DB.open("#{ADMIN_URL}#{separator}#{query}") { |database| yield database }
end

private def count_of_server_statements(database : DB::Database, sql : String) : Int64
  database.query_one("SELECT count(*) FROM pg_prepared_statements WHERE statement = $1", sql, as: Int64)
end

private def scratch_table(suffix : String) : String
  "grant_driver_named_#{suffix}_#{Random.rand(1_000_000)}"
end

describe Grant::PG::Statement, "named statements" do
  describe "default behavior" do
    it "keeps one server-side statement after 1,000 calls with correct values" do
      with_one_connection do |database|
        table = scratch_table("thousand")
        database.exec "CREATE TABLE #{table} (id bigint PRIMARY KEY, label text NOT NULL)"
        database.exec "INSERT INTO #{table} SELECT n, 'row ' || n FROM generate_series(1, 1000) AS n"
        lookup = "SELECT label FROM #{table} WHERE id = $1"

        (1_i64..1000_i64).each do |id|
          database.query_one(lookup, id, as: String).should eq "row #{id}"
        end

        count_of_server_statements(database, lookup).should eq 1
        database.exec "DROP TABLE #{table}"
      end
    end

    it "names each query separately under a generated name" do
      with_one_connection do |database|
        database.query_one("SELECT 1 + $1::int", 1, as: Int32).should eq 2
        database.query_one("SELECT 2 + $1::int", 1, as: Int32).should eq 3

        names = database.query_all("SELECT name FROM pg_prepared_statements ORDER BY name", as: String)
        names.size.should eq names.uniq.size
        names.all?(&.starts_with?("grant_")).should be_true
      end
    end

    it "binds a NULL parameter" do
      with_one_connection do |database|
        database.query_one("SELECT $1::text IS NULL", nil, as: Bool).should be_true
        database.query_one("SELECT $1::text IS NULL", nil, as: Bool).should be_true
        database.query_one("SELECT $1::text IS NULL", "value", as: Bool).should be_false
      end
    end

    it "runs a statement with no parameters and one that returns no rows" do
      with_one_connection do |database|
        database.query_one("SELECT 41 + 1", as: Int32).should eq 42
        database.exec("SET statement_timeout = 0").rows_affected.should eq 0
        database.exec("SET statement_timeout = 0").rows_affected.should eq 0
      end
    end

    it "leaves the connection usable after a failed parse" do
      with_one_connection do |database|
        bad_query = "SELECT missing_column_for_grant FROM pg_class WHERE oid = $1"
        2.times do
          expect_raises(Grant::PQ::PQError, /missing_column_for_grant/) do
            database.query_one(bad_query, 1, as: Int64)
          end
        end

        database.query_one("SELECT 7", as: Int32).should eq 7
        count_of_server_statements(database, bad_query).should eq 0
      end
    end

    it "keeps working after a Bind error on a freshly parsed statement" do
      with_one_connection do |database|
        lookup = "SELECT $1::int"
        expect_raises(Grant::PQ::PQError, /invalid input syntax/) do
          database.query_one(lookup, "not a number", as: Int32)
        end

        database.query_one(lookup, "5", as: Int32).should eq 5
        count_of_server_statements(database, lookup).should eq 1
      end
    end

    it "keeps a statement parsed inside a rolled-back transaction" do
      with_one_connection do |database|
        lookup = "SELECT 11 + $1::int"
        database.transaction do |transaction|
          transaction.connection.query_one(lookup, 1, as: Int32).should eq 12
          transaction.rollback
        end

        database.query_one(lookup, 2, as: Int32).should eq 13
        count_of_server_statements(database, lookup).should eq 1
      end
    end
  end

  describe "when statements are turned off" do
    it "holds no server-side statements with prepared_statements=false" do
      with_one_connection("prepared_statements=false") do |database|
        lookup = "SELECT $1::int + 1"
        20.times { database.query_one(lookup, 1, as: Int32).should eq 2 }

        count_of_server_statements(database, lookup).should eq 0
      end
    end

    it "holds no server-side statements with prepared_statements_cache=false" do
      with_one_connection("prepared_statements_cache=false") do |database|
        lookup = "SELECT $1::int + 2"
        20.times { database.query_one(lookup, 1, as: Int32).should eq 3 }

        count_of_server_statements(database, lookup).should eq 0
      end
    end
  end

  describe "stale server-side statements" do
    it "recovers when a column changes type while the connection stays open" do
      with_one_connection do |database|
        table = scratch_table("type_change")
        database.exec "CREATE TABLE #{table} (id bigint PRIMARY KEY, amount int NOT NULL)"
        database.exec "INSERT INTO #{table} VALUES (1, 42)"
        lookup = "SELECT amount FROM #{table} WHERE id = $1"

        database.query_one(lookup, 1_i64, as: Int32).should eq 42
        database.exec "ALTER TABLE #{table} ALTER COLUMN amount TYPE text"
        database.query_one(lookup, 1_i64, as: String).should eq "42"

        count_of_server_statements(database, lookup).should eq 1
        database.exec "DROP TABLE #{table}"
      end
    end

    it "does not apply a write twice when it recovers" do
      with_one_connection do |database|
        table = scratch_table("write_once")
        database.exec "CREATE TABLE #{table} (id bigserial PRIMARY KEY, amount int NOT NULL)"
        insert = "INSERT INTO #{table} (amount) VALUES ($1) RETURNING amount"

        database.query_one(insert, 1, as: Int32).should eq 1
        database.exec "ALTER TABLE #{table} ALTER COLUMN amount TYPE bigint"
        database.query_one(insert, 2, as: Int64).should eq 2_i64

        database.query_one("SELECT count(*) FROM #{table}", as: Int64).should eq 2
        database.exec "DROP TABLE #{table}"
      end
    end

    it "recovers when a parameter's column changes type on a write" do
      with_one_connection do |database|
        table = scratch_table("param_type")
        database.exec "CREATE TABLE #{table} (amount int NOT NULL)"
        insert = "INSERT INTO #{table} (amount) VALUES ($1)"

        database.exec insert, 1
        database.exec "ALTER TABLE #{table} ALTER COLUMN amount TYPE text"
        database.exec insert, "two"

        database.query_all("SELECT amount FROM #{table} ORDER BY amount", as: String).should eq ["1", "two"]
        database.exec "DROP TABLE #{table}"
      end
    end

    it "recovers when the server has forgotten the statement" do
      with_one_connection do |database|
        lookup = "SELECT 21 + $1::int"
        database.query_one(lookup, 1, as: Int32).should eq 22
        database.exec "DEALLOCATE ALL"

        database.query_one(lookup, 2, as: Int32).should eq 23
        count_of_server_statements(database, lookup).should eq 1
      end
    end

    it "reports the error inside a transaction and re-parses after rollback" do
      with_one_connection do |database|
        table = scratch_table("in_transaction")
        database.exec "CREATE TABLE #{table} (id bigint PRIMARY KEY, amount int NOT NULL)"
        database.exec "INSERT INTO #{table} VALUES (1, 42)"
        lookup = "SELECT amount FROM #{table} WHERE id = $1"
        database.query_one(lookup, 1_i64, as: Int32).should eq 42
        database.exec "ALTER TABLE #{table} ALTER COLUMN amount TYPE text"

        database.transaction do |transaction|
          expect_raises(Grant::PQ::PQError, /cached plan must not change result type/) do
            transaction.connection.query_one(lookup, 1_i64, as: String)
          end
          transaction.rollback
        end

        database.query_one(lookup, 1_i64, as: String).should eq "42"
        database.exec "DROP TABLE #{table}"
      end
    end

    it "reports the error after a savepoint rollback and re-parses on next use" do
      with_one_connection do |database|
        table = scratch_table("savepoint")
        database.exec "CREATE TABLE #{table} (id bigint PRIMARY KEY, amount int NOT NULL)"
        database.exec "INSERT INTO #{table} VALUES (1, 42)"
        lookup = "SELECT amount FROM #{table} WHERE id = $1"
        database.query_one(lookup, 1_i64, as: Int32).should eq 42
        database.exec "ALTER TABLE #{table} ALTER COLUMN amount TYPE text"

        database.transaction do |transaction|
          connection = transaction.connection
          connection.exec "SAVEPOINT grant_spec_point"
          expect_raises(Grant::PQ::PQError, /cached plan must not change result type/) do
            connection.query_one(lookup, 1_i64, as: String)
          end
          connection.exec "ROLLBACK TO SAVEPOINT grant_spec_point"
          connection.query_one(lookup, 1_i64, as: String).should eq "42"
          transaction.commit
        end

        database.exec "DROP TABLE #{table}"
      end
    end
  end
end
