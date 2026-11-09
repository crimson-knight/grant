require "spec"

{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "../../../../src/grant/drivers/pg/pg"

private PG_DATABASE_URL = ENV["PG_DATABASE_URL"]? || "postgres:///"

private def plain_pg_server_settings
  port = ENV["GRANT_PG_PLAIN_PORT"]?
  database = ENV["GRANT_PG_TLS_DATABASE"]?

  if port && database
    {port: port, database: database}
  end
end

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

# PostgreSQL rejects a parameter it cannot infer a type for, so the query uses all of them.
private def query_using_every_parameter(count : Int32) : String
  placeholders = (1..count).join(",") { |number| "$#{number}" }
  "SELECT max(value)::integer FROM unnest(ARRAY[#{placeholders}]::integer[]) AS value"
end

private def list_of_parameter_values(count : Int32) : Array(Int32)
  Array(Int32).new(count) { |index| index + 1 }
end

private def conn_info_for_plain_pg_server(port : String, database : String, user : String, password : String? = nil) : Grant::PQ::ConnInfo
  Grant::PQ::ConnInfo.new(
    host: "127.0.0.1",
    port: port,
    database: database,
    user: user,
    password: password,
    sslmode: :disable
  )
end

private def with_pg_driver_connection(conn_info : Grant::PQ::ConnInfo, & : Grant::PG::Connection ->)
  connection = Grant::PG::Connection.new(DB::Connection::Options.new, conn_info)

  begin
    yield connection
  ensure
    connection.close
  end
end

describe Grant::PQ::Connection, "large bind parameter counts (D19)" do
  context "golden behavior" do
    it "returns the right row with 40,000 parameters" do
      with_one_pg_database do |database|
        parameter_count = 40_000
        query = query_using_every_parameter(parameter_count)
        database.query_one(query, args: list_of_parameter_values(parameter_count), as: Int32).should eq parameter_count
      end
    end
  end

  context "at the boundary" do
    it "returns the right row with 65,535 parameters" do
      with_one_pg_database do |database|
        parameter_count = 65_535
        query = query_using_every_parameter(parameter_count)
        database.query_one(query, args: list_of_parameter_values(parameter_count), as: Int32).should eq parameter_count
      end
    end
  end

  context "just past the boundary" do
    it "refuses 65,536 parameters before sending bytes and keeps the pool connection usable" do
      with_one_pg_database do |database|
        original_backend_pid = database.query_one("SELECT pg_backend_pid()", as: Int32)
        parameter_count = 65_536
        query = query_using_every_parameter(parameter_count)

        expect_raises(Grant::PQ::TooManyParametersError, /65535.*65536/) do
          database.query_one(query, args: list_of_parameter_values(parameter_count), as: Int32)
        end

        next_backend_pid, next_value = backend_pid_and_integer(database, 73)
        next_backend_pid.should eq original_backend_pid
        next_value.should eq 73
      end
    end
  end

  describe "UTF-8 startup and password lengths" do
    it "connects with a non-ASCII PostgreSQL username" do
      if settings = plain_pg_server_settings
        conn_info = conn_info_for_plain_pg_server(settings[:port], settings[:database], "päss")
        with_pg_driver_connection(conn_info) do |connection|
          connection.query_one("SELECT current_user", as: String).should eq "päss"
        end
      else
        pending!("needs GRANT_PG_PLAIN_PORT and GRANT_PG_TLS_DATABASE")
      end
    end

    it "authenticates a cleartext password with non-ASCII characters" do
      if settings = plain_pg_server_settings
        conn_info = conn_info_for_plain_pg_server(settings[:port], settings[:database], "cleartext_role", "pässwörd")
        conn_info.auth_methods << "cleartext"
        with_pg_driver_connection(conn_info) do |connection|
          connection.query_one("SELECT current_user", as: String).should eq "cleartext_role"
        end
      else
        pending!("needs GRANT_PG_PLAIN_PORT and GRANT_PG_TLS_DATABASE")
      end
    end

    it "rejects a wrong password with the same character count" do
      if settings = plain_pg_server_settings
        conn_info = conn_info_for_plain_pg_server(settings[:port], settings[:database], "cleartext_role", "pässwörx")
        conn_info.auth_methods << "cleartext"
        pq_connection = Grant::PQ::Connection.new(conn_info)

        begin
          expect_raises(Grant::PQ::PQError) do
            pq_connection.connect
          end
        ensure
          pq_connection.close
        end
      else
        pending!("needs GRANT_PG_PLAIN_PORT and GRANT_PG_TLS_DATABASE")
      end
    end
  end
end
