require "spec"

{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "socket"
require "socket/tcp_server"
require "socket/tcp_socket"
require "../../../../src/grant/drivers/pg/pg"

private def tls_server_settings
  tls_port = ENV["GRANT_PG_TLS_PORT"]?
  database = ENV["GRANT_PG_TLS_DATABASE"]?

  if tls_port && database
    {
      tls_port:          tls_port,
      database:          database,
      ca_file:           ENV["GRANT_PG_TLS_CA_FILE"]?,
      unrelated_ca_file: ENV["GRANT_PG_TLS_UNRELATED_CA_FILE"]?,
    }
  end
end

private def plain_server_settings
  port = ENV["GRANT_PG_PLAIN_PORT"]?
  database = ENV["GRANT_PG_TLS_DATABASE"]?

  if port && database
    {port: port, database: database}
  end
end

private def pg_connection_info(host : String, port : String, database : String, sslmode : String, ca_file : String? = nil) : Grant::PQ::ConnInfo
  conninfo = "host=#{host} port=#{port} dbname=#{database} user=postgres sslmode=#{sslmode}"
  conninfo += " sslrootcert=#{ca_file}" if ca_file
  Grant::PQ::ConnInfo.from_conninfo_string(conninfo)
end

private def with_pg_connection(conn_info : Grant::PQ::ConnInfo, & : Grant::PG::Connection ->)
  connection = Grant::PG::Connection.new(DB::Connection::Options.new, conn_info)

  begin
    yield connection
  ensure
    connection.close
  end
end

private def expect_tls_refusal_from_local_server(sslmode : Symbol)
  server = TCPServer.new("127.0.0.1", 0)
  socket_eof = Channel(UInt8?).new

  spawn do
    client = server.accept
    request = Bytes.new(8)
    client.read_fully(request)
    client << 'N'
    client.flush
    socket_eof.send(client.read_byte)
  ensure
    client.try(&.close)
    server.close
  end

  conn_info = Grant::PQ::ConnInfo.new(
    host: "127.0.0.1",
    port: server.local_address.port,
    database: "unused",
    user: "unused",
    sslmode: sslmode
  )

  expect_raises(Grant::PQ::ConnectionError, /sslmode=#{sslmode}/) do
    Grant::PQ::Connection.new(conn_info)
  end
  socket_eof.receive.should be_nil
end

describe Grant::PQ::Connection, "TLS certificate verification (D1)" do
  context "golden behavior" do
    it "verifies the certificate and host for verify-full to localhost" do
      if settings = tls_server_settings
        if ca_file = settings[:ca_file]
          conn_info = pg_connection_info("localhost", settings[:tls_port], settings[:database], "verify-full", ca_file)
          with_pg_connection(conn_info) do |connection|
            connection.query_one("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", as: Bool).should be_true
          end
        else
          pending!("needs GRANT_PG_TLS_CA_FILE")
        end
      else
        pending!("needs GRANT_PG_TLS_PORT and GRANT_PG_TLS_DATABASE")
      end
    end

    it "keeps require encrypted without certificate verification" do
      if settings = tls_server_settings
        conn_info = pg_connection_info("localhost", settings[:tls_port], settings[:database], "require")
        with_pg_connection(conn_info) do |connection|
          connection.query_one("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", as: Bool).should be_true
        end
      else
        pending!("needs GRANT_PG_TLS_PORT and GRANT_PG_TLS_DATABASE")
      end
    end
  end

  context "at the boundary" do
    it "accepts the trusted chain for verify-ca when the IP does not match the certificate name" do
      if settings = tls_server_settings
        if ca_file = settings[:ca_file]
          conn_info = pg_connection_info("127.0.0.1", settings[:tls_port], settings[:database], "verify-ca", ca_file)
          with_pg_connection(conn_info) do |connection|
            connection.query_one("SELECT 1", as: Int32).should eq 1
          end
        else
          pending!("needs GRANT_PG_TLS_CA_FILE")
        end
      else
        pending!("needs GRANT_PG_TLS_PORT and GRANT_PG_TLS_DATABASE")
      end
    end
  end

  context "just past the boundary" do
    it "rejects the trusted chain when verify-full sees the wrong IP name" do
      if settings = tls_server_settings
        if ca_file = settings[:ca_file]
          conn_info = pg_connection_info("127.0.0.1", settings[:tls_port], settings[:database], "verify-full", ca_file)
          expect_raises(DB::ConnectionRefused) do
            with_pg_connection(conn_info) { |connection| connection.query_one("SELECT 1", as: Int32) }
          end
        else
          pending!("needs GRANT_PG_TLS_CA_FILE")
        end
      else
        pending!("needs GRANT_PG_TLS_PORT and GRANT_PG_TLS_DATABASE")
      end
    end

    it "rejects an unrelated authority for verify-ca and verify-full" do
      if settings = tls_server_settings
        if unrelated_ca_file = settings[:unrelated_ca_file]
          [:"verify-ca", :"verify-full"].each do |sslmode|
            conn_info = pg_connection_info("localhost", settings[:tls_port], settings[:database], sslmode.to_s, unrelated_ca_file)
            expect_raises(DB::ConnectionRefused) do
              with_pg_connection(conn_info) { |connection| connection.query_one("SELECT 1", as: Int32) }
            end
          end
        else
          pending!("needs GRANT_PG_TLS_UNRELATED_CA_FILE")
        end
      else
        pending!("needs GRANT_PG_TLS_PORT and GRANT_PG_TLS_DATABASE")
      end
    end

    it "rejects a plain server for require, verify-ca, and verify-full" do
      if plain_settings = plain_server_settings
        [:require, :"verify-ca", :"verify-full"].each do |sslmode|
          conn_info = pg_connection_info("127.0.0.1", plain_settings[:port], plain_settings[:database], sslmode.to_s)
          expect_raises(DB::ConnectionRefused) do
            with_pg_connection(conn_info) { |connection| connection.query_one("SELECT 1", as: Int32) }
          end
        end
      else
        pending!("needs GRANT_PG_PLAIN_PORT and GRANT_PG_TLS_DATABASE")
      end
    end
  end

  it "closes the socket and names each sslmode when a server answers N" do
    [:require, :"verify-ca", :"verify-full"].each do |sslmode|
      expect_tls_refusal_from_local_server(sslmode)
    end
  end
end
