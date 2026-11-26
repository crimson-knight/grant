require "../../spec_helper"

private def pg_environment_for(url : String) : Hash(String, String)
  Grant::Schema::ConnectionSettings.parse(url).pg_environment
end

private def with_ssl_cert_file(path : String?, &)
  previous = ENV["SSL_CERT_FILE"]?
  path ? (ENV["SSL_CERT_FILE"] = path) : ENV.delete("SSL_CERT_FILE")
  begin
    yield
  ensure
    previous ? (ENV["SSL_CERT_FILE"] = previous) : ENV.delete("SSL_CERT_FILE")
  end
end

describe Grant::Schema::ConnectionSettings do
  describe "#pg_environment" do
    it "passes sslmode and sslrootcert from the URL, with TLS 1.3 as the floor" do
      environment = pg_environment_for("postgres://grant:agentc-placeholder%3Alocal-dev-only@db.example.com:5432/app?sslmode=verify-full&sslrootcert=%2Fetc%2Fapp%2Fca.pem")

      environment.should eq({
        "PGPASSWORD"              => "agentc-placeholder:local-dev-only",
        "PGSSLMODE"               => "verify-full",
        "PGSSLMINPROTOCOLVERSION" => "TLSv1.3",
        "PGSSLROOTCERT"           => "/etc/app/ca.pem",
      })
    end

    it "passes sslrootcert for verify-ca" do
      environment = pg_environment_for("postgres://grant@db.example.com/app?sslmode=verify-ca&sslrootcert=%2Fetc%2Fapp%2Fca.pem")

      environment["PGSSLMODE"].should eq("verify-ca")
      environment["PGSSLROOTCERT"].should eq("/etc/app/ca.pem")
    end

    it "points libpq at the anchors the driver trusts when sslrootcert is absent or system" do
      bundle = File.tempname("grant-system-bundle", ".pem")
      File.write(bundle, Grant::Beryl::Certificates::TrustStore.mozilla.list_of_certificates.first(2).join(&.to_pem))
      begin
        with_ssl_cert_file(bundle) do
          when_absent = pg_environment_for("postgres://grant@db.example.com/app?sslmode=verify-full")["PGSSLROOTCERT"]
          when_system = pg_environment_for("postgres://grant@db.example.com/app?sslmode=verify-full&sslrootcert=system")["PGSSLROOTCERT"]
          when_system.should eq(when_absent)
          {% if flag?(:darwin) %}
            # libpq reads one file, so Grant writes TrustStore.system's set.
            when_absent.should start_with(Grant::Schema::WriteTrustAnchorsForCommandLineTools.cache_directory)
            Grant::Beryl::Certificates::TrustStore.from_pem(File.read(when_absent)).list_of_certificates
              .should eq(Grant::Beryl::Certificates::TrustStore.system.list_of_certificates)
          {% else %}
            when_absent.should eq(bundle)
          {% end %}
        end
      ensure
        File.delete?(bundle)
      end
    end

    {% if flag?(:darwin) %}
      it "gives libpq /etc/ssl/cert.pem joined with Beryl's pinned Mozilla roots on macOS" do
        with_ssl_cert_file(nil) do
          path = pg_environment_for("postgres://grant@db.example.com/app?sslmode=verify-full")["PGSSLROOTCERT"]

          Grant::Beryl::Certificates::TrustStore.from_pem(File.read(path)).list_of_certificates
            .should eq(Grant::Beryl::Certificates::TrustStore.system.list_of_certificates)
          path.should_not eq("/etc/ssl/cert.pem")
        end
      end
    {% end %}

    it "raises a StructureToolError when verification needs a system bundle that is missing" do
      with_ssl_cert_file("/nonexistent/grant-bundle.pem") do
        expect_raises(Grant::Schema::StructureToolError, /sslmode=verify-full needs trust anchors/) do
          pg_environment_for("postgres://grant@db.example.com/app?sslmode=verify-full")
        end
      end
    end

    it "passes client certificate and key paths" do
      environment = pg_environment_for("postgres://grant@db.example.com/app?sslmode=require&sslcert=%2Fk%2Fclient.pem&sslkey=%2Fk%2Fclient.key")

      environment["PGSSLCERT"].should eq("/k/client.pem")
      environment["PGSSLKEY"].should eq("/k/client.key")
      environment.has_key?("PGSSLROOTCERT").should be_false
    end

    it "uses the driver's default sslmode when the URL names none" do
      pg_environment_for("postgres://grant@localhost/app").should eq({"PGSSLMODE" => "disable"})
      pg_environment_for("postgres://grant@127.0.0.1/app")["PGSSLMODE"].should eq("disable")
      pg_environment_for("postgres://grant@[::1]/app")["PGSSLMODE"].should eq("disable")
      pg_environment_for("postgres://grant@db.example.com/app")["PGSSLMODE"].should eq("prefer")
      pg_environment_for("postgres://grant@10.0.0.5/app")["PGSSLMODE"].should eq("prefer")
    end

    it "sets no TLS floor when sslmode is disable" do
      pg_environment_for("postgres://grant@db.example.com/app?sslmode=disable").should eq({"PGSSLMODE" => "disable"})
    end
  end
end

# Against the TLS 1.3 test server (scripts/pg-tls-test-servers.sh): libpq,
# given only what `pg_environment` sets, accepts the server under the URL's
# own CA and refuses it under an unrelated one, as Grant's driver does.
describe "pg_dump with Grant::Schema::ConnectionSettings#pg_environment" do
  it "verifies the server against the URL's sslrootcert" do
    pg_dump = Process.find_executable("pg_dump")
    unrelated_ca_file = ENV["GRANT_PG_TLS_UNRELATED_CA_FILE"]?
    next unless CURRENT_ADAPTER == "pg" && pg_dump && unrelated_ca_file && ADAPTER_URL.includes?("sslmode=verify-full")

    trusted = Grant::Schema::ConnectionSettings.parse(ADAPTER_URL)
    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run(pg_dump, ["--schema-only"] + trusted.pg_arguments, env: trusted.pg_environment, output: output, error: error)
    status.success?.should be_true, "pg_dump under the URL's CA failed: #{error}"

    uri = URI.parse(ADAPTER_URL)
    query = uri.query_params
    query["sslrootcert"] = unrelated_ca_file
    uri.query = query.to_s
    untrusted = Grant::Schema::ConnectionSettings.parse(uri.to_s)
    error = IO::Memory.new
    status = Process.run(pg_dump, ["--schema-only"] + untrusted.pg_arguments, env: untrusted.pg_environment, output: Process::Redirect::Close, error: error)
    status.success?.should be_false
    error.to_s.should match(/certificate verify failed|certificate/i)
  end

  it "verifies the server against the anchors SSL_CERT_FILE names when the URL names no sslrootcert" do
    pg_dump = Process.find_executable("pg_dump")
    unrelated_ca_file = ENV["GRANT_PG_TLS_UNRELATED_CA_FILE"]?
    next unless CURRENT_ADAPTER == "pg" && pg_dump && unrelated_ca_file && ADAPTER_URL.includes?("sslmode=verify-full")

    uri = URI.parse(ADAPTER_URL)
    query = uri.query_params
    ca_file = query["sslrootcert"]?
    next unless ca_file
    query.delete("sslrootcert")
    uri.query = query.to_s
    settings = Grant::Schema::ConnectionSettings.parse(uri.to_s)

    with_ssl_cert_file(ca_file) do
      error = IO::Memory.new
      status = Process.run(pg_dump, ["--schema-only"] + settings.pg_arguments, env: settings.pg_environment, output: Process::Redirect::Close, error: error)
      status.success?.should be_true, "pg_dump under SSL_CERT_FILE=#{ca_file} failed: #{error}"
    end

    with_ssl_cert_file(unrelated_ca_file) do
      error = IO::Memory.new
      status = Process.run(pg_dump, ["--schema-only"] + settings.pg_arguments, env: settings.pg_environment, output: Process::Redirect::Close, error: error)
      status.success?.should be_false
      error.to_s.should match(/certificate verify failed|certificate/i)
    end
  end
end
