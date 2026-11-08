require "spec"

{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "../spec_helper"
require "../../../../../../src/grant/drivers/pg/pq/conninfo"

private def assert_default_params(ci)
  (Grant::PQ::ConnInfo::SOCKET_SEARCH + ["localhost"]).should contain(ci.host)
  ci.database.should_not eq(nil)
  ci.user.should_not eq(nil)
  ci.database.should eq(ci.user)
  ci.password.should eq(nil)
  ci.port.should eq(5432)
  # Grant: a database on this machine defaults to no encryption.
  ci.sslmode.should eq(:disable)
  ci.application_name.should eq("crystal")
end

private def assert_custom_params(ci)
  ci.host.should eq("host")
  ci.database.should eq("db")
  ci.user.should eq("user")
  ci.password.should eq("pass")
  ci.port.should eq(5555)
  ci.sslmode.should eq(:require)
  ci.application_name.should eq("specs")
end

private def assert_ssl_params(ci)
  ci.sslmode.should eq(:"verify-full")
  ci.sslcert.should eq("postgresql.crt")
  ci.sslkey.should eq("postgresql.key")
  ci.sslrootcert.should eq("root.crt")
end

describe Grant::PQ::ConnInfo, "parts" do
  it "can have all defaults" do
    pg_driver_env_var_bubble do
      ci = Grant::PQ::ConnInfo.new
      assert_default_params ci
    end
  end

  it "can take settings" do
    ci = Grant::PQ::ConnInfo.new("host", "db", "user", "pass", 5555, :require, "specs")
    assert_custom_params ci
  end
end

describe Grant::PQ::ConnInfo, ".from_conninfo_string" do
  it "parses short postgres urls" do
    pg_driver_env_var_bubble do
      ci = Grant::PQ::ConnInfo.from_conninfo_string("postgres:///")
      assert_default_params ci
    end
  end

  it "parses postgres urls" do
    ci = Grant::PQ::ConnInfo.from_conninfo_string(
      "postgres://user:pass@host:5555/db?sslmode=require&otherparam=ignore&application_name=specs")
    assert_custom_params ci

    ci = Grant::PQ::ConnInfo.from_conninfo_string(
      "postgres://user:pass@host:5555/db?sslmode=verify-full&sslcert=postgresql.crt&sslkey=postgresql.key&sslrootcert=root.crt")
    assert_ssl_params ci

    ci = Grant::PQ::ConnInfo.from_conninfo_string(
      "postgresql://user:pass@host:5555/db?sslmode=require&application_name=specs")
    assert_custom_params ci
  end

  it "parses postgres host from socket query string host" do
    ci = Grant::PQ::ConnInfo.from_conninfo_string(
      "postgresql://user:pass@/db?host=/sql/socket")

    ci.host.should eq "/sql/socket"
  end

  it "parses libpq style strings" do
    ci = Grant::PQ::ConnInfo.from_conninfo_string(
      "host=host dbname=db user=user password=pass port=5555 sslmode=require application_name=specs")
    assert_custom_params ci

    ci = Grant::PQ::ConnInfo.from_conninfo_string(
      "host=host dbname=db user=user password=pass port=5555 sslmode=verify-full sslcert=postgresql.crt sslkey=postgresql.key sslrootcert=root.crt")
    assert_ssl_params ci

    ci = Grant::PQ::ConnInfo.from_conninfo_string("host=host")
    ci.host.should eq("host")

    pg_driver_env_var_bubble do
      ci = Grant::PQ::ConnInfo.from_conninfo_string("")
      assert_default_params ci
    end

    expect_raises(ArgumentError) {
      Grant::PQ::ConnInfo.from_conninfo_string("hosthost")
    }
  end

  it "parses an IPv6 host" do
    ci = Grant::PQ::ConnInfo.from_conninfo_string("postgres://user:pass@[::1]:5555/db")
    ci.host.should eq("::1")
  end

  it "auth_methods" do
    ci = Grant::PQ::ConnInfo.from_conninfo_string("postgres://user:pass@localhost/foo")
    ci.auth_methods.should eq ["scram-sha-256-plus", "scram-sha-256", "md5"]

    ci = Grant::PQ::ConnInfo.from_conninfo_string("postgres://user:pass@localhost/foo?auth_methods=md5")
    ci.auth_methods.should eq ["md5"]

    ci = Grant::PQ::ConnInfo.from_conninfo_string("postgres://user:pass@localhost/foo?auth_methods=")
    ci.auth_methods.should eq [] of String

    ci = Grant::PQ::ConnInfo.from_conninfo_string("postgres://user:pass@localhost/foo?auth_methods=cleartext,md5,scram-sha-256")
    ci.auth_methods.should eq ["cleartext", "md5", "scram-sha-256"]

    expect_raises Exception do
      Grant::PQ::ConnInfo.from_conninfo_string("postgres://user:pass@localhost/foo?auth_methods=unsupported")
    end
    expect_raises Exception do
      Grant::PQ::ConnInfo.from_conninfo_string("postgres://user:pass@localhost/foo?auth_methods=md5,unsupported")
    end
  end

  it "uses environment variables" do
    pg_driver_env_var_bubble do
      ENV["PGDATABASE"] = "A"
      ENV["PGHOST"] = "B"
      ENV["PGPASSWORD"] = "C" # secret-scan-gate:allow (upstream one-letter fixture)
      ENV["PGPORT"] = "1"
      ENV["PGUSER"] = "D"
      ENV["PGAPPNAME"] = "S"
      ci = Grant::PQ::ConnInfo.from_conninfo_string("postgres://")
      ci.database.should eq("A")
      ci.host.should eq("B")
      ci.password.should eq("C")
      ci.port.should eq(1)
      ci.user.should eq("D")
      ci.application_name.should eq("S")
    end

    pg_driver_env_var_bubble do
      ENV["PGHOST"] = "/path"
      ci = Grant::PQ::ConnInfo.from_conninfo_string("postgres://")
      ci.host.should eq("/path")
    end
  end
end
