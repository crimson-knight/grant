require "spec"

{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "../../../../src/grant/drivers/pg/pg"

private def sslmode_for(url : String) : Symbol
  Grant::PQ::ConnInfo.new(URI.parse(url)).sslmode
end

describe Grant::PQ::ConnInfo, "default sslmode" do
  describe "when the database is on this machine" do
    it "is disable for a Unix socket directory" do
      sslmode_for("postgres:///app?host=/tmp").should eq :disable
      sslmode_for("postgres:///app?host=/var/run/postgresql").should eq :disable
    end

    it "is disable for localhost in any case" do
      sslmode_for("postgres://localhost/app").should eq :disable
      sslmode_for("postgres://LocalHost:5433/app").should eq :disable
    end

    it "is disable for the IPv4 loopback range" do
      sslmode_for("postgres://127.0.0.1/app").should eq :disable
      sslmode_for("postgres://127.0.0.2:5433/app").should eq :disable
      sslmode_for("postgres://127.255.255.254/app").should eq :disable
    end

    it "is disable for the IPv6 loopback address" do
      sslmode_for("postgres://[::1]/app").should eq :disable
      sslmode_for("postgres://[::1]:5433/app").should eq :disable
      sslmode_for("postgres://[0:0:0:0:0:0:0:1]/app").should eq :disable
    end

    it "is disable for a socket path given through the key-value form" do
      Grant::PQ::ConnInfo.from_conninfo_string("host=/tmp dbname=app").sslmode.should eq :disable
      Grant::PQ::ConnInfo.new(host: "127.0.0.1", database: "app").sslmode.should eq :disable
    end
  end

  describe "when the database is on another machine" do
    it "stays prefer for a hostname" do
      sslmode_for("postgres://db.example.com/app").should eq :prefer
    end

    it "stays prefer for a private address" do
      sslmode_for("postgres://10.0.0.5/app").should eq :prefer
      sslmode_for("postgres://192.168.1.10/app").should eq :prefer
      sslmode_for("postgres://[2001:db8::1]/app").should eq :prefer
    end

    it "stays prefer for a hostname that only looks like a loopback address" do
      sslmode_for("postgres://127.0.0.1.nip.io/app").should eq :prefer
      sslmode_for("postgres://127.evil.example/app").should eq :prefer
      sslmode_for("postgres://localhost.example.com/app").should eq :prefer
    end
  end

  describe "with an explicit sslmode" do
    it "keeps the sslmode given in the URL for a database on this machine" do
      sslmode_for("postgres://localhost/app?sslmode=require").should eq :require
      sslmode_for("postgres://127.0.0.1/app?sslmode=prefer").should eq :prefer
      sslmode_for("postgres:///app?host=/tmp&sslmode=verify-full").should eq :"verify-full"
      sslmode_for("postgres://[::1]/app?sslmode=allow").should eq :allow
    end

    it "keeps disable on another machine" do
      sslmode_for("postgres://db.example.com/app?sslmode=disable").should eq :disable
    end

    it "keeps the sslmode given in other forms" do
      Grant::PQ::ConnInfo.from_conninfo_string("host=localhost sslmode=require").sslmode.should eq :require
      Grant::PQ::ConnInfo.new(host: "127.0.0.1", sslmode: :prefer).sslmode.should eq :prefer
    end
  end
end
