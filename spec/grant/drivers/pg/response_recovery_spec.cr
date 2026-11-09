require "spec"

{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "../../../../src/grant/drivers/pg/pg"

private PG_DATABASE_URL = ENV["PG_DATABASE_URL"]? || "postgres:///"

private def with_one_pg_database(& : DB::Database ->)
  separator = PG_DATABASE_URL.includes?("?") ? "&" : "?"
  pool_options = "initial_pool_size=1&max_pool_size=1&max_idle_pool_size=1"

  DB.open("#{PG_DATABASE_URL}#{separator}#{pool_options}") do |database|
    yield database
  end
end

private def backend_pid_and_integer(database : DB::Database, integer_value : Int32) : {Int32, Int32}
  database.query_one("SELECT pg_backend_pid(), #{integer_value}") do |result_set|
    {result_set.read(Int32), result_set.read(Int32)}
  end
end

describe Grant::PQ::Connection, "response recovery (D8)" do
  context "golden behavior" do
    it "keeps the same backend after a server syntax error" do
      with_one_pg_database do |database|
        backend_pid = database.query_one("SELECT pg_backend_pid()", as: Int32)

        expect_raises(Grant::PQ::PQError, /syntax error/) do
          database.exec("SELECT FROM")
        end

        database.query_one("SELECT pg_backend_pid()", as: Int32).should eq backend_pid
      end
    end
  end

  context "at the boundary" do
    it "returns the next query's value immediately after a drained server error" do
      with_one_pg_database do |database|
        backend_pid = database.query_one("SELECT pg_backend_pid()", as: Int32)

        expect_raises(Grant::PQ::PQError) do
          database.exec("SELECT missing_column_for_d8 FROM pg_class")
        end

        next_backend_pid, next_value = backend_pid_and_integer(database, 47)
        next_backend_pid.should eq backend_pid
        next_value.should eq 47
      end
    end
  end

  context "just past the boundary" do
    it "closes after the client_encoding error and gives later queries their own answers" do
      with_one_pg_database do |database|
        table = "grant_d8_once_#{Random.rand(1_000_000)}"
        database.exec("CREATE TABLE #{table} (execution_count integer NOT NULL)")
        database.exec("INSERT INTO #{table} VALUES (0)")
        original_backend_pid = database.query_one("SELECT pg_backend_pid()", as: Int32)
        failing_statement = "WITH statement_run AS MATERIALIZED (UPDATE #{table} SET execution_count = execution_count + 1 RETURNING execution_count) SELECT set_config('client_encoding', 'LATIN1', false) FROM statement_run"

        begin
          expect_raises(Grant::PQ::ConnectionError, /Only UTF8/) do
            database.exec(failing_statement)
          end

          first_backend_pid, first_value = backend_pid_and_integer(database, 1)
          second_backend_pid, second_value = backend_pid_and_integer(database, 2)

          first_backend_pid.should_not eq original_backend_pid
          second_backend_pid.should eq first_backend_pid
          first_value.should eq 1
          second_value.should eq 2
          database.query_one("SELECT execution_count FROM #{table}", as: Int32).should eq 1
        ensure
          database.exec("DROP TABLE IF EXISTS #{table}")
        end
      end
    end
  end
end
