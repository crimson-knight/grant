require "spec"

{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "file_utils"
require "openssl"
require "process"
require "random/secure"
require "socket"
require "socket/tcp_server"
require "socket/tcp_socket"
require "../../../../src/grant/drivers/pg/pg"

private record LocalTLSCertificates,
  ca_certificate_file : String,
  leaf_certificate_file : String,
  leaf_private_key_file : String,
  unrelated_ca_certificate_file : String

private record LocalTLSAttempt,
  startup_declared_length : Int32?,
  startup_payload : Bytes?,
  client_error : Exception?,
  server_error : Exception?

private def run_openssl(arguments : Array(String)) : Nil
  error_output = IO::Memory.new
  status = Process.run("openssl", arguments, output: Process::Redirect::Close, error: error_output)
  raise "openssl #{arguments.first} failed: #{error_output}" unless status.success?
end

private def with_local_tls_certificates(& : LocalTLSCertificates -> T) : T forall T
  temporary_directory = File.join(Dir.tempdir, "grant_pg_tls_#{Process.pid}_#{Random::Secure.hex(6)}")
  Dir.mkdir_p(temporary_directory)

  ca_key_file = File.join(temporary_directory, "ca.key")
  ca_certificate_file = File.join(temporary_directory, "ca.crt")
  leaf_key_file = File.join(temporary_directory, "leaf.key")
  leaf_request_file = File.join(temporary_directory, "leaf.csr")
  leaf_certificate_file = File.join(temporary_directory, "leaf.crt")
  leaf_extensions_file = File.join(temporary_directory, "leaf.ext")
  unrelated_ca_key_file = File.join(temporary_directory, "unrelated-ca.key")
  unrelated_ca_certificate_file = File.join(temporary_directory, "unrelated-ca.crt")

  begin
    File.write(leaf_extensions_file, <<-EXTENSIONS)
      [server_certificate]
      subjectAltName=DNS:localhost
      basicConstraints=critical,CA:FALSE
      keyUsage=critical,digitalSignature,keyEncipherment
      extendedKeyUsage=serverAuth
      EXTENSIONS

    run_openssl([
      "req", "-x509", "-newkey", "rsa:2048", "-nodes",
      "-keyout", ca_key_file, "-out", ca_certificate_file,
      "-subj", "/CN=Grant Local TLS CA", "-days", "2",
      "-addext", "basicConstraints=critical,CA:TRUE",
      "-addext", "keyUsage=critical,keyCertSign,cRLSign",
    ])
    run_openssl([
      "req", "-x509", "-newkey", "rsa:2048", "-nodes",
      "-keyout", unrelated_ca_key_file, "-out", unrelated_ca_certificate_file,
      "-subj", "/CN=Grant Unrelated TLS CA", "-days", "2",
      "-addext", "basicConstraints=critical,CA:TRUE",
      "-addext", "keyUsage=critical,keyCertSign,cRLSign",
    ])
    run_openssl([
      "req", "-new", "-newkey", "rsa:2048", "-nodes",
      "-keyout", leaf_key_file, "-out", leaf_request_file,
      "-subj", "/CN=localhost",
    ])
    run_openssl([
      "x509", "-req", "-in", leaf_request_file,
      "-CA", ca_certificate_file, "-CAkey", ca_key_file,
      "-CAcreateserial", "-out", leaf_certificate_file,
      "-days", "2", "-extfile", leaf_extensions_file,
      "-extensions", "server_certificate",
    ])

    yield LocalTLSCertificates.new(
      ca_certificate_file,
      leaf_certificate_file,
      leaf_key_file,
      unrelated_ca_certificate_file
    )
  ensure
    FileUtils.rm_rf(temporary_directory)
  end
end

private def expect_local_startup_frame(attempt : LocalTLSAttempt, first_user : String) : Nil
  attempt.client_error.should be_nil
  attempt.server_error.should be_nil

  unless startup_length = attempt.startup_declared_length
    raise "The TLS server did not receive a startup frame"
  end
  unless startup_payload = attempt.startup_payload
    raise "The TLS server did not receive the complete startup frame"
  end

  startup_length.should eq startup_payload.size + 4
  startup_message = String.new(startup_payload)
  startup_message.should contain(first_user)
  startup_message.ends_with?("\0\0").should be_true
end

# Points OpenSSL's default trust store at *certificate_file* for the block.
private def with_system_certificate_file(certificate_file : String, &)
  previous_value = ENV["SSL_CERT_FILE"]?
  ENV["SSL_CERT_FILE"] = certificate_file
  yield
ensure
  ENV["SSL_CERT_FILE"] = previous_value
end

private def attempt_local_tls_startup(host : String, sslmode : String, ca_file : String?, certificates : LocalTLSCertificates) : LocalTLSAttempt
  server = TCPServer.new("127.0.0.1", 0)
  server_context = OpenSSL::SSL::Context::Server.new
  server_context.certificate_chain = certificates.leaf_certificate_file
  server_context.private_key = certificates.leaf_private_key_file
  server_observation = Channel({Int32?, Bytes?, Exception?}).new
  server_finished = Channel(Nil).new

  spawn do
    startup_declared_length : Int32? = nil
    startup_payload : Bytes? = nil
    server_error : Exception? = nil
    tcp_client : TCPSocket? = nil

    begin
      tcp_client = server.accept
      if client = tcp_client
        ssl_request_length = client.read_bytes(Int32, IO::ByteFormat::NetworkEndian)
        ssl_request_code = client.read_bytes(Int32, IO::ByteFormat::NetworkEndian)
        unless ssl_request_length == 8 && ssl_request_code == 80_877_103
          raise "The TLS test server received an invalid SSLRequest"
        end

        client << 'S'
        client.flush
        tls_client = OpenSSL::SSL::Socket::Server.new(client, context: server_context, sync_close: true)
        declared_startup_frame_length = tls_client.read_bytes(Int32, IO::ByteFormat::NetworkEndian)
        startup_declared_length = declared_startup_frame_length
        raise "The TLS client sent an invalid startup frame length" if declared_startup_frame_length < 8

        startup_payload = Bytes.new(declared_startup_frame_length - 4)
        tls_client.read_fully(startup_payload)
      end
    rescue ex
      server_error = ex
    ensure
      if client = tcp_client
        client.close unless client.closed?
      end
      server.close
      server_observation.send({startup_declared_length, startup_payload, server_error})
      server_finished.send(nil)
    end
  end

  conn_info = pg_connection_info(host, server.local_address.port.to_s, "tls_probe", sslmode, ca_file)
  client_error : Exception? = nil
  connection : Grant::PQ::Connection? = nil

  begin
    connection = Grant::PQ::Connection.new(conn_info)
    connection.startup(["user", "päss", "database", "tls_probe"])
  rescue ex
    client_error = ex
  ensure
    if pg_connection = connection
      begin
        pg_connection.soc.close
      rescue IO::Error
        # The local TLS server closes after observing the startup frame.
      rescue OpenSSL::SSL::Error
        # The peer may have completed its close before the client did.
      end
    end
  end

  startup_length, startup_payload, server_error = server_observation.receive
  server_finished.receive
  LocalTLSAttempt.new(startup_length, startup_payload, client_error, server_error)
end

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
  {% unless flag?(:win32) %}
    context "with an in-process TLS server" do
      context "golden behavior" do
        it "sends startup after verify-full accepts localhost with the trusted chain" do
          with_local_tls_certificates do |certificates|
            attempt = attempt_local_tls_startup("localhost", "verify-full", certificates.ca_certificate_file, certificates)
            expect_local_startup_frame(attempt, "päss")
          end
        end
      end

      context "at the boundary" do
        it "uses the system store when sslrootcert is absent" do
          with_local_tls_certificates do |certificates|
            with_system_certificate_file(certificates.ca_certificate_file) do
              attempt = attempt_local_tls_startup("localhost", "verify-full", nil, certificates)
              expect_local_startup_frame(attempt, "päss")
            end
          end
        end

        it "sends startup after verify-ca accepts the trusted chain for an IP host" do
          with_local_tls_certificates do |certificates|
            attempt = attempt_local_tls_startup("127.0.0.1", "verify-ca", certificates.ca_certificate_file, certificates)
            expect_local_startup_frame(attempt, "päss")
          end
        end
      end

      context "just past the boundary" do
        it "refuses verify-full for the wrong IP name before startup" do
          with_local_tls_certificates do |certificates|
            attempt = attempt_local_tls_startup("127.0.0.1", "verify-full", certificates.ca_certificate_file, certificates)

            attempt.client_error.should be_a(OpenSSL::SSL::Error)
            attempt.startup_declared_length.should be_nil
            attempt.startup_payload.should be_nil
          end
        end

        it "keeps sslrootcert as the only trust anchor when the system store trusts the server" do
          with_local_tls_certificates do |certificates|
            with_system_certificate_file(certificates.ca_certificate_file) do
              attempt = attempt_local_tls_startup("localhost", "verify-full", certificates.unrelated_ca_certificate_file, certificates)

              attempt.client_error.should be_a(OpenSSL::SSL::Error)
              attempt.startup_payload.should be_nil
            end
          end
        end

        it "refuses verify-ca for an unrelated authority before startup" do
          with_local_tls_certificates do |certificates|
            attempt = attempt_local_tls_startup("localhost", "verify-ca", certificates.unrelated_ca_certificate_file, certificates)

            attempt.client_error.should be_a(OpenSSL::SSL::Error)
            attempt.startup_declared_length.should be_nil
            attempt.startup_payload.should be_nil
          end
        end
      end
    end
  {% end %}

  context "golden behavior" do
    it "uses the trusted root for verify-full to localhost when the platform supports it" do
      if settings = tls_server_settings
        if ca_file = settings[:ca_file]
          conn_info = pg_connection_info("localhost", settings[:tls_port], settings[:database], "verify-full", ca_file)
          {% if flag?(:win32) %}
            expect_raises(Grant::PQ::ConnectionError, /sslmode=verify-full.*exclusive sslrootcert trust is unavailable on Windows/) do
              Grant::PQ::Connection.new(conn_info)
            end
          {% else %}
            with_pg_connection(conn_info) do |connection|
              connection.query_one("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", as: Bool).should be_true
            end
          {% end %}
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
    it "uses chain-only verify-ca for an IP host when the platform supports it" do
      if settings = tls_server_settings
        if ca_file = settings[:ca_file]
          conn_info = pg_connection_info("127.0.0.1", settings[:tls_port], settings[:database], "verify-ca", ca_file)
          {% if flag?(:win32) %}
            expect_raises(Grant::PQ::ConnectionError, /sslmode=verify-ca.*exclusive sslrootcert trust is unavailable on Windows/) do
              Grant::PQ::Connection.new(conn_info)
            end
          {% else %}
            with_pg_connection(conn_info) do |connection|
              connection.query_one("SELECT 1", as: Int32).should eq 1
            end
          {% end %}
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

  {% if flag?(:win32) %}
    it "names the sslmode when exclusive sslrootcert trust is unavailable on Windows" do
      with_local_tls_certificates do |certificates|
        attempt = attempt_local_tls_startup("localhost", "verify-ca", certificates.ca_certificate_file, certificates)

        if connection_error = attempt.client_error
          connection_error.should be_a(Grant::PQ::ConnectionError)
          connection_error.message.to_s.should contain("sslmode=verify-ca")
          connection_error.message.to_s.should contain("exclusive sslrootcert trust is unavailable on Windows")
        else
          raise "Expected Windows sslrootcert verification to fail closed"
        end
        attempt.startup_declared_length.should be_nil
      end
    end
  {% end %}
end
