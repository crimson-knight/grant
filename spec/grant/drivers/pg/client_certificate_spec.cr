require "spec"

{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "file_utils"
{% if flag?(:use_openssl) %}
  require "openssl"
{% end %}
require "process"
require "random/secure"
require "socket"
require "socket/tcp_server"
require "socket/tcp_socket"
require "../../../../src/grant/drivers/pg/pg"

# Client certificates (mutual TLS): the sslcert and sslkey parameters, the
# libpq key-permission rule, the TLS context they build, a handshake with an
# in-process Beryl server that requires a certificate, and, when the
# GRANT_PG_CLIENTCERT_* variables name one, a PostgreSQL server whose
# pg_hba.conf says `hostssl all all all cert clientcert=verify-full`.

private record ClientCertificateFiles,
  ca_certificate_file : String,
  server_certificate_file : String,
  server_private_key_file : String,
  client_certificate_file : String,
  client_private_key_file : String,
  unrelated_client_certificate_file : String,
  unrelated_client_private_key_file : String

private record ClientCertificateHandshake,
  client_error : Exception?,
  server_error : Exception?,
  client_common_name : String?

private def run_openssl_for_client_certificates(arguments : Array(String)) : Nil
  error_output = IO::Memory.new
  status = Process.run("openssl", arguments, output: Process::Redirect::Close, error: error_output)
  raise "openssl #{arguments.first} failed: #{error_output}" unless status.success?
end

private def make_certificate_authority(directory : String, base_name : String, common_name : String) : {String, String}
  key_file = File.join(directory, "#{base_name}.key")
  certificate_file = File.join(directory, "#{base_name}.crt")
  run_openssl_for_client_certificates([
    "req", "-x509", "-newkey", "rsa:2048", "-nodes",
    "-keyout", key_file, "-out", certificate_file,
    "-subj", "/CN=#{common_name}", "-days", "2",
    "-addext", "basicConstraints=critical,CA:TRUE",
    "-addext", "keyUsage=critical,keyCertSign,cRLSign",
  ])
  {certificate_file, key_file}
end

private def make_signed_certificate(directory : String, base_name : String, common_name : String,
                                    authority : {String, String}, extensions : String) : {String, String}
  key_file = File.join(directory, "#{base_name}.key")
  request_file = File.join(directory, "#{base_name}.csr")
  certificate_file = File.join(directory, "#{base_name}.crt")
  extensions_file = File.join(directory, "#{base_name}.ext")
  File.write(extensions_file, "[leaf]\n#{extensions}\n")
  run_openssl_for_client_certificates([
    "req", "-new", "-newkey", "rsa:2048", "-nodes",
    "-keyout", key_file, "-out", request_file, "-subj", "/CN=#{common_name}",
  ])
  run_openssl_for_client_certificates([
    "x509", "-req", "-in", request_file,
    "-CA", authority[0], "-CAkey", authority[1], "-CAcreateserial",
    "-out", certificate_file, "-days", "2",
    "-extfile", extensions_file, "-extensions", "leaf",
  ])
  File.chmod(key_file, 0o600)
  {certificate_file, key_file}
end

private def with_client_certificate_files(& : ClientCertificateFiles -> T) : T forall T
  directory = File.join(Dir.tempdir, "grant_pg_client_certificate_#{Process.pid}_#{Random::Secure.hex(6)}")
  Dir.mkdir_p(directory)

  begin
    authority = make_certificate_authority(directory, "ca", "Grant Client Certificate CA")
    unrelated_authority = make_certificate_authority(directory, "unrelated-ca", "Grant Unrelated CA")
    server = make_signed_certificate(directory, "server", "localhost", authority,
      "subjectAltName=DNS:localhost\nbasicConstraints=critical,CA:FALSE\n" \
      "keyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth")
    client_extensions = "basicConstraints=critical,CA:FALSE\n" \
                        "keyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth"
    client = make_signed_certificate(directory, "client", "grant_client", authority, client_extensions)
    unrelated_client = make_signed_certificate(directory, "unrelated-client", "grant_client", unrelated_authority, client_extensions)

    yield ClientCertificateFiles.new(authority[0], server[0], server[1], client[0], client[1],
      unrelated_client[0], unrelated_client[1])
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def client_certificate_conninfo(port : Int32, sslmode : String, ca_file : String,
                                        certificate_file : String?, private_key_file : String?) : Grant::PQ::ConnInfo
  url = "postgres://grant_client@localhost:#{port}/tls_probe?sslmode=#{sslmode}&sslrootcert=#{ca_file}"
  url += "&sslcert=#{certificate_file}" if certificate_file
  url += "&sslkey=#{private_key_file}" if private_key_file
  Grant::PQ::ConnInfo.from_conninfo_string(url)
end

# Runs one handshake against an in-process Beryl server that requires a
# client certificate issued by the test authority, and reports the common
# name of the certificate the server received.
private def attempt_client_certificate_handshake(files : ClientCertificateFiles, sslmode : String,
                                                 certificate_file : String?, private_key_file : String?) : ClientCertificateHandshake
  server = TCPServer.new("127.0.0.1", 0)
  server_context = Grant::Beryl::TLS::Context::Server.new
  server_context.certificate_chain = files.server_certificate_file
  server_context.private_key = files.server_private_key_file
  server_context.client_verify_mode = Grant::Beryl::TLS::ClientVerifyMode::Required
  server_context.client_ca_certificates = files.ca_certificate_file
  server_outcome = Channel({String?, Exception?}).new

  spawn do
    client_common_name : String? = nil
    server_error : Exception? = nil
    tcp_client : TCPSocket? = nil
    begin
      tcp_client = server.accept
      if client = tcp_client
        client.read_bytes(Int32, IO::ByteFormat::NetworkEndian)
        client.read_bytes(Int32, IO::ByteFormat::NetworkEndian)
        client << 'S'
        client.flush
        tls_client = Grant::Beryl::TLS::Socket::Server.new(client, server_context, sync_close: true)
        tls_client.read_bytes(Int32, IO::ByteFormat::NetworkEndian)
        if peer_certificate = tls_client.peer_certificate
          client_common_name = peer_certificate.subject.to_s
        end
      end
    rescue ex
      server_error = ex
    ensure
      if client = tcp_client
        client.close unless client.closed?
      end
      server.close
      server_outcome.send({client_common_name, server_error})
    end
  end

  conninfo = client_certificate_conninfo(server.local_address.port, sslmode, files.ca_certificate_file,
    certificate_file, private_key_file)
  client_error : Exception? = nil
  connection : Grant::PQ::Connection? = nil
  begin
    connection = Grant::PQ::Connection.new(conninfo)
    connection.startup(["user", "grant_client", "database", "tls_probe"])
  rescue ex
    client_error = ex
  end

  client_common_name, server_error = server_outcome.receive
  if pg_connection = connection
    begin
      pg_connection.soc.close
    rescue IO::Error | Grant::Beryl::TLS::Error
      # The test server has already closed its side.
    end
  end
  ClientCertificateHandshake.new(client_error, server_error, client_common_name)
end

# The client context of the TLS library this build uses.
{% if flag?(:use_openssl) %}
  private def new_client_tls_context : OpenSSL::SSL::Context::Client
    OpenSSL::SSL::Context::Client.new
  end
{% else %}
  private def new_client_tls_context : Grant::Beryl::TLS::Context::Client
    Grant::Beryl::TLS::Context::Client.new
  end
{% end %}

private def with_private_key_permissions(private_key_file : String, permissions : Int32, &)
  File.chmod(private_key_file, permissions)
  yield
ensure
  File.chmod(private_key_file, 0o600)
end

private def clientcert_server_settings
  port = ENV["GRANT_PG_CLIENTCERT_PORT"]?
  database = ENV["GRANT_PG_CLIENTCERT_DATABASE"]?
  user = ENV["GRANT_PG_CLIENTCERT_USER"]?
  ca_file = ENV["GRANT_PG_CLIENTCERT_SERVER_CA_FILE"]?
  certificate_file = ENV["GRANT_PG_CLIENTCERT_CERT_FILE"]?
  private_key_file = ENV["GRANT_PG_CLIENTCERT_KEY_FILE"]?

  if port && database && user && ca_file && certificate_file && private_key_file
    {port: port, database: database, user: user, ca_file: ca_file,
     certificate_file: certificate_file, private_key_file: private_key_file}
  end
end

private def clientcert_server_url(settings, with_certificate : Bool) : String
  url = "postgres://#{settings[:user]}@localhost:#{settings[:port]}/#{settings[:database]}" \
        "?sslmode=verify-full&sslrootcert=#{settings[:ca_file]}"
  url += "&sslcert=#{settings[:certificate_file]}&sslkey=#{settings[:private_key_file]}" if with_certificate
  url
end

describe Grant::PQ::ConnInfo, "client certificate parameters" do
  it "reads sslcert and sslkey from a connection URL" do
    conninfo = Grant::PQ::ConnInfo.from_conninfo_string(
      "postgres://app@db.example.com/app_db?sslmode=verify-full&sslcert=/etc/app/client.crt&sslkey=/etc/app/client.key")
    conninfo.sslcert.should eq "/etc/app/client.crt"
    conninfo.sslkey.should eq "/etc/app/client.key"
  end

  it "reads sslcert and sslkey from key-value pairs" do
    conninfo = Grant::PQ::ConnInfo.from_conninfo_string(
      "host=db.example.com dbname=app_db sslmode=require sslcert=/etc/app/client.crt sslkey=/etc/app/client.key")
    conninfo.sslcert.should eq "/etc/app/client.crt"
    conninfo.sslkey.should eq "/etc/app/client.key"
  end

  it "decodes percent-encoded paths in a URL" do
    conninfo = Grant::PQ::ConnInfo.from_conninfo_string(
      "postgres://app@db.example.com/app_db?sslcert=%2Fsrv%2Fmy%20app%2Fclient.crt&sslkey=%2Fsrv%2Fmy%20app%2Fclient.key")
    conninfo.sslcert.should eq "/srv/my app/client.crt"
    conninfo.sslkey.should eq "/srv/my app/client.key"
  end

  it "leaves both nil when the connection names neither" do
    conninfo = Grant::PQ::ConnInfo.from_conninfo_string("postgres://app@db.example.com/app_db?sslmode=require")
    conninfo.sslcert.should be_nil
    conninfo.sslkey.should be_nil
  end
end

describe Grant::PQ::ClientCertificate do
  describe ".from" do
    it "returns the certificate and key paths when both are given" do
      conninfo = Grant::PQ::ConnInfo.from_conninfo_string(
        "postgres://app@db.example.com/app_db?sslcert=/etc/app/client.crt&sslkey=/etc/app/client.key")
      if client_certificate = Grant::PQ::ClientCertificate.from(conninfo)
        client_certificate.certificate_path.should eq "/etc/app/client.crt"
        client_certificate.private_key_path.should eq "/etc/app/client.key"
      else
        raise "Expected a client certificate"
      end
    end

    it "returns nil when neither is given" do
      conninfo = Grant::PQ::ConnInfo.from_conninfo_string("postgres://app@db.example.com/app_db")
      Grant::PQ::ClientCertificate.from(conninfo).should be_nil
    end

    it "refuses sslcert without sslkey" do
      conninfo = Grant::PQ::ConnInfo.from_conninfo_string("postgres://app@db.example.com/app_db?sslcert=/etc/app/client.crt")
      expect_raises(Grant::PQ::ConnectionError, /sslcert=\/etc\/app\/client\.crt was given without sslkey/) do
        Grant::PQ::ClientCertificate.from(conninfo)
      end
    end

    it "refuses sslkey without sslcert" do
      conninfo = Grant::PQ::ConnInfo.from_conninfo_string("postgres://app@db.example.com/app_db?sslkey=/etc/app/client.key")
      expect_raises(Grant::PQ::ConnectionError, /sslkey=\/etc\/app\/client\.key was given without sslcert/) do
        Grant::PQ::ClientCertificate.from(conninfo)
      end
    end
  end

  {% unless flag?(:win32) %}
    describe "#refuse_a_private_key_open_to_others" do
      it "accepts a key readable by its owner only (0600 and 0400)" do
        with_client_certificate_files do |files|
          client_certificate = Grant::PQ::ClientCertificate.new(files.client_certificate_file, files.client_private_key_file)
          [0o600, 0o400].each do |permissions|
            with_private_key_permissions(files.client_private_key_file, permissions) do
              client_certificate.refuse_a_private_key_open_to_others
            end
          end
        end
      end

      it "refuses a key readable by the group (0640) or by others (0604, 0644)" do
        with_client_certificate_files do |files|
          client_certificate = Grant::PQ::ClientCertificate.new(files.client_certificate_file, files.client_private_key_file)
          [0o640, 0o604, 0o644].each do |permissions|
            with_private_key_permissions(files.client_private_key_file, permissions) do
              expect_raises(Grant::PQ::ConnectionError, /has group or world access .*u=rw \(0600\) or less/) do
                client_certificate.refuse_a_private_key_open_to_others
              end
            end
          end
        end
      end

      it "names the missing key file" do
        client_certificate = Grant::PQ::ClientCertificate.new("/nonexistent/client.crt", "/nonexistent/client.key")
        expect_raises(Grant::PQ::ConnectionError, /sslkey=\/nonexistent\/client\.key could not be read/) do
          client_certificate.refuse_a_private_key_open_to_others
        end
      end

      it "refuses a key path that is a directory" do
        client_certificate = Grant::PQ::ClientCertificate.new("/nonexistent/client.crt", Dir.tempdir)
        expect_raises(Grant::PQ::ConnectionError, /is not a regular file/) do
          client_certificate.refuse_a_private_key_open_to_others
        end
      end
    end
  {% end %}

  describe "#apply_to" do
    {% unless flag?(:use_openssl) %}
      it "gives a Beryl client context the chain and key to present" do
        with_client_certificate_files do |files|
          tls_context = Grant::Beryl::TLS::Context::Client.new
          tls_context.certified_key?.should be_nil

          Grant::PQ::ClientCertificate.new(files.client_certificate_file, files.client_private_key_file).apply_to(tls_context)

          if certified_key = tls_context.certified_key?
            certified_key.list_of_certificates.first.subject.to_s.should contain("grant_client")
          else
            raise "Expected the context to hold the client certificate"
          end
        end
      end
    {% end %}

    it "names sslcert when the certificate file is not PEM" do
      with_client_certificate_files do |files|
        tls_context = new_client_tls_context
        client_certificate = Grant::PQ::ClientCertificate.new(files.client_private_key_file, files.client_private_key_file)
        expect_raises(Grant::PQ::ConnectionError, /sslcert=/) do
          client_certificate.apply_to(tls_context)
        end
      end
    end
  end
end

describe Grant::PQ::Connection, "client certificates (mutual TLS)" do
  {% unless flag?(:win32) %}
    context "with an in-process TLS server that requires a client certificate" do
      it "presents the certificate for every sslmode that uses TLS" do
        with_client_certificate_files do |files|
          %w[prefer require verify-ca verify-full].each do |sslmode|
            handshake = attempt_client_certificate_handshake(files, sslmode,
              files.client_certificate_file, files.client_private_key_file)
            handshake.client_error.should be_nil
            handshake.server_error.should be_nil
            handshake.client_common_name.to_s.should contain("grant_client")
          end
        end
      end

      it "is refused by the server when no certificate is given" do
        with_client_certificate_files do |files|
          handshake = attempt_client_certificate_handshake(files, "verify-full", nil, nil)
          handshake.client_common_name.should be_nil
          handshake.server_error.to_s.should contain("requires one")
        end
      end

      it "is refused by the server when the certificate comes from another authority" do
        with_client_certificate_files do |files|
          handshake = attempt_client_certificate_handshake(files, "verify-full",
            files.unrelated_client_certificate_file, files.unrelated_client_private_key_file)
          handshake.client_common_name.should be_nil
          handshake.server_error.should_not be_nil
        end
      end

      it "stops before the handshake when the key is readable by others" do
        with_client_certificate_files do |files|
          with_private_key_permissions(files.client_private_key_file, 0o644) do
            server = TCPServer.new("127.0.0.1", 0)
            spawn do
              if client = server.accept?
                client.read_bytes(Int64, IO::ByteFormat::NetworkEndian)
                client << 'S'
                client.flush
                client.read_byte
                client.close
              end
            end
            conninfo = client_certificate_conninfo(server.local_address.port, "verify-full", files.ca_certificate_file,
              files.client_certificate_file, files.client_private_key_file)
            expect_raises(Grant::PQ::ConnectionError, /group or world access/) do
              Grant::PQ::Connection.new(conninfo)
            end
            server.close
          end
        end
      end
    end
  {% end %}

  context "with a PostgreSQL server whose pg_hba.conf requires a client certificate" do
    it "logs in as the certificate's common name when the certificate is given" do
      settings = clientcert_server_settings || pending!("needs the GRANT_PG_CLIENTCERT_* variables")
      conninfo = Grant::PQ::ConnInfo.from_conninfo_string(clientcert_server_url(settings, with_certificate: true))
      connection = Grant::PG::Connection.new(DB::Connection::Options.new, conninfo)
      begin
        connection.query_one("SELECT current_user", as: String).should eq settings[:user]
        connection.query_one("SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()", as: String).should eq "TLSv1.3"
        connection.query_one("SELECT client_dn FROM pg_stat_ssl WHERE pid = pg_backend_pid()", as: String)
          .should contain("CN=#{settings[:user]}")
      ensure
        connection.close
      end
    end

    it "is refused with a message naming the certificate when none is given" do
      settings = clientcert_server_settings || pending!("needs the GRANT_PG_CLIENTCERT_* variables")
      conninfo = Grant::PQ::ConnInfo.from_conninfo_string(clientcert_server_url(settings, with_certificate: false))
      error = expect_raises(DB::ConnectionRefused) do
        Grant::PG::Connection.new(DB::Connection::Options.new, conninfo)
      end
      error.cause.to_s.should match(/certificate/i)
    end
  end
end
