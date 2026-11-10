require "spec"

{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "../../../../src/grant/drivers/pg/pg"
require "../../../../src/grant"
require "../../../../src/adapter/pg"

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

private def with_one_pg_adapter(& : Grant::Adapter::Pg ->)
  separator = PG_DATABASE_URL.includes?("?") ? "&" : "?"
  pool_options = "initial_pool_size=1&max_pool_size=1&max_idle_pool_size=1"
  adapter = Grant::Adapter::Pg.new(name: "grant_d8_result_set_close", url: "#{PG_DATABASE_URL}#{separator}#{pool_options}")
  adapter.verify_idle_after = nil

  begin
    yield adapter
  ensure
    adapter.disconnect!
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

  context "when a notice handler raises a driver or pool error" do
    it "does not treat a server-style error from the callback as a drained response" do
      with_one_pg_database do |database|
        database.using_connection do |connection|
          connection.as(Grant::PG::Connection).on_notice do
            raise Grant::PQ::PQError.new([] of Grant::PQ::Frame::ErrorResponse::Field)
          end
        end

        expect_raises(Grant::PQ::ConnectionError, /Response callback failed/) do
          database.exec("DO $body$ BEGIN RAISE NOTICE 'probe'; END $body$")
        end

        database.query_one("SELECT 11", as: Int32).should eq 11
        database.query_one("SELECT 12", as: Int32).should eq 12
      end
    end

    it "does not let a retryable error from the callback run the statement again" do
      sequence_name = "grant_d8_lost_#{Random.rand(1_000_000)}"
      function_name = "#{sequence_name}_call"

      with_one_pg_database do |database|
        database.exec("CREATE SEQUENCE #{sequence_name}")
        database.exec("CREATE FUNCTION #{function_name}() RETURNS void LANGUAGE plpgsql AS $body$ BEGIN PERFORM nextval('#{sequence_name}'); RAISE NOTICE 'probe'; END $body$")

        begin
          database.using_connection do |connection|
            connection.as(Grant::PG::Connection).on_notice { raise DB::ConnectionLost.new(connection) }
          end

          expect_raises(Grant::PQ::ConnectionError, /Response callback failed/) do
            database.exec("SELECT #{function_name}()")
          end

          database.query_one("SELECT last_value FROM #{sequence_name}", as: Int64).should eq 1
        ensure
          database.exec("DROP FUNCTION IF EXISTS #{function_name}()")
          database.exec("DROP SEQUENCE IF EXISTS #{sequence_name}")
        end
      end
    end
  end

  context "when a notice handler raises IO::Error" do
    it "closes the connection and leaves the statement run once" do
      sequence_name = "grant_d8_notice_#{Random.rand(1_000_000)}"
      function_name = "#{sequence_name}_call"

      with_one_pg_database do |database|
        database.exec("CREATE SEQUENCE #{sequence_name}")
        database.exec("CREATE FUNCTION #{function_name}() RETURNS void LANGUAGE plpgsql AS $body$ BEGIN PERFORM nextval('#{sequence_name}'); RAISE NOTICE 'probe'; END $body$")

        begin
          database.using_connection do |connection|
            connection.as(Grant::PG::Connection).on_notice { raise IO::Error.new("notice handler failed") }
          end

          expect_raises(Grant::PQ::ConnectionError, /notice handler failed/) do
            database.exec("SELECT #{function_name}()")
          end

          database.query_one("SELECT last_value FROM #{sequence_name}", as: Int64).should eq 1
        ensure
          database.exec("DROP FUNCTION IF EXISTS #{function_name}()")
          database.exec("DROP SEQUENCE IF EXISTS #{sequence_name}")
        end
      end
    end
  end

  context "when a result set closes" do
    it "drains unread rows before a waiting fiber checks out the only connection" do
      with_one_pg_adapter do |adapter|
        result_set = adapter.database.query("SELECT repeat('x', 131072) FROM generate_series(1, 32)")
        waiter_result = Channel({Int32?, Exception?}).new(1)

        begin
          result_set.move_next.should be_true
          result_set.read(String).size.should eq 131_072

          spawn do
            value = adapter.open do |connection|
              connection.query_one("SELECT 42", as: Int32)
            end
            waiter_result.send({value, nil})
          rescue ex
            waiter_result.send({nil, ex})
          end

          100.times do
            break if adapter.pool_stat.waiting == 1
            Fiber.yield
          end
          adapter.pool_stat.waiting.should eq 1

          result_set.close

          waiter_value, waiter_error = waiter_result.receive
          waiter_error.should be_nil
          waiter_value.should eq 42
        ensure
          result_set.close
        end
      end
    end
  end
end
