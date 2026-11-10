require "spec"

{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "socket"
require "socket/tcp_server"
require "socket/tcp_socket"
require "../../../../src/grant/drivers/pg/pg"

private PG_DATABASE_URL = ENV["PG_DATABASE_URL"]? || "postgres:///"

private record LocalWireLengthObservation,
  startup_declared_length : Int32?,
  startup_payload : Bytes?,
  password_message_type : Char?,
  password_declared_length : Int32?,
  password_payload : Bytes?,
  server_error : Exception?,
  client_error : Exception?

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

private def send_cleartext_authentication_request(socket : TCPSocket) : Nil
  socket << 'R'
  socket.write_bytes(8_i32, IO::ByteFormat::NetworkEndian)
  socket.write_bytes(3_i32, IO::ByteFormat::NetworkEndian)
  socket.flush
end

private def send_authentication_success(socket : TCPSocket) : Nil
  socket << 'R'
  socket.write_bytes(8_i32, IO::ByteFormat::NetworkEndian)
  socket.write_bytes(0_i32, IO::ByteFormat::NetworkEndian)
  socket << 'Z'
  socket.write_bytes(5_i32, IO::ByteFormat::NetworkEndian)
  socket << 'I'
  socket.flush
end

private def read_cleartext_password_message(socket : TCPSocket) : {Char?, Int32?, Bytes?}
  message_type = socket.read_char
  return {message_type, nil, nil} unless message_type == 'p'

  declared_length = socket.read_bytes(Int32, IO::ByteFormat::NetworkEndian)
  raise "The password frame length is invalid" if declared_length < 4 || declared_length > 1_000_000

  payload = Bytes.new(declared_length - 4)
  socket.read_fully(payload)
  {message_type, declared_length, payload}
end

private def run_in_process_cleartext_server_probe : LocalWireLengthObservation
  server = TCPServer.new("127.0.0.1", 0)
  observations = Channel(LocalWireLengthObservation).new

  spawn do
    startup_declared_length : Int32? = nil
    startup_payload : Bytes? = nil
    password_message_type : Char? = nil
    password_declared_length : Int32? = nil
    password_payload : Bytes? = nil
    server_error : Exception? = nil
    client : TCPSocket? = nil

    begin
      client = server.accept
      if socket = client
        declared_startup_frame_length = socket.read_bytes(Int32, IO::ByteFormat::NetworkEndian)
        startup_declared_length = declared_startup_frame_length
        if declared_startup_frame_length < 8 || declared_startup_frame_length > 1_000_000
          raise "The startup frame length is invalid"
        end
        startup_payload = Bytes.new(declared_startup_frame_length - 4)
        socket.read_fully(startup_payload)

        send_cleartext_authentication_request(socket)
        password_message_type, password_declared_length, password_payload = read_cleartext_password_message(socket)
        send_authentication_success(socket)
      end
    rescue ex
      server_error = ex
    ensure
      if socket = client
        socket.close unless socket.closed?
      end
      server.close
      observations.send(LocalWireLengthObservation.new(
        startup_declared_length,
        startup_payload,
        password_message_type,
        password_declared_length,
        password_payload,
        server_error,
        nil
      ))
    end
  end

  client_error : Exception? = nil
  connection : Grant::PQ::Connection? = nil
  begin
    conn_info = Grant::PQ::ConnInfo.new(
      host: "127.0.0.1",
      port: server.local_address.port,
      database: "grant_wire_probe",
      user: "päss",
      password: "agentc-placeholder:local-dev-only-pässwörd",
      sslmode: :disable
    )
    conn_info.auth_methods << "cleartext"
    connection = Grant::PQ::Connection.new(conn_info)
    connection.connect
  rescue ex
    client_error = ex
  ensure
    if pg_connection = connection
      begin
        pg_connection.close
      rescue IO::Error
        # The local server may already have closed its socket after a frame error.
      end
    end
  end

  observation = observations.receive
  server.close unless server.closed?
  LocalWireLengthObservation.new(
    observation.startup_declared_length,
    observation.startup_payload,
    observation.password_message_type,
    observation.password_declared_length,
    observation.password_payload,
    observation.server_error,
    client_error
  )
end

describe Grant::PQ::Connection, "large bind parameter counts (D19)" do
  describe "UTF-8 byte lengths on an in-process server" do
    it "declares and sends non-ASCII startup and cleartext password bytes" do
      observation = run_in_process_cleartext_server_probe

      observation.server_error.should be_nil
      observation.client_error.should be_nil

      unless startup_declared_length = observation.startup_declared_length
        raise "The server did not receive a startup frame"
      end
      unless startup_payload = observation.startup_payload
        raise "The server did not receive the complete startup payload"
      end
      startup_declared_length.should eq startup_payload.size + 4
      startup_message = String.new(startup_payload)
      startup_message.should contain("päss")
      startup_message.ends_with?("\0\0").should be_true

      observation.password_message_type.should eq 'p'
      unless password_declared_length = observation.password_declared_length
        raise "The server did not receive a complete password frame"
      end
      unless password_payload = observation.password_payload
        raise "The server did not receive a password payload"
      end
      password_declared_length.should eq password_payload.size + 4
      String.new(password_payload).should eq "agentc-placeholder:local-dev-only-pässwörd\0"
    end
  end

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
