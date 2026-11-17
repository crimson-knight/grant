require "../../../spec_helper"

# Audit defect D11: LISTEN and replication connections must be built by Grant's
# own PostgreSQL driver even when another driver (the public `pg` shard, in a
# real app) registered the shared `postgres` and `postgresql` schemes last.
{% if (env("CURRENT_ADAPTER") || "sqlite") == "pg" %}
  class ListenSchemeRefusingDriver < DB::Driver
    def connection_builder(uri : URI) : DB::ConnectionBuilder
      raise DB::Error.new("the public #{uri.scheme} scheme was used")
    end
  end

  class ListenSchemeForeignConnection < DB::Connection
    class_property? closed_once = false

    def build_prepared_statement(query) : DB::Statement
      raise DB::Error.new("foreign connection")
    end

    def build_unprepared_statement(query) : DB::Statement
      raise DB::Error.new("foreign connection")
    end

    protected def do_close
      self.class.closed_once = true
    end
  end

  class ListenSchemeForeignDriver < DB::Driver
    class Builder < DB::ConnectionBuilder
      def initialize(@options : DB::Connection::Options)
      end

      def build : DB::Connection
        ListenSchemeForeignConnection.new(@options)
      end
    end

    def connection_builder(uri : URI) : DB::ConnectionBuilder
      Builder.new(connection_options(HTTP::Params.parse(uri.query || "")))
    end
  end

  class ListenSchemeReplicationHandler
    include Grant::PG::Replication::Handler

    def received(data : Grant::PG::Replication::XLogData, connection : Grant::PG::Replication::Connection, &)
      yield
    end
  end

  private def listen_scheme_url(scheme : String) : String
    ADAPTER_URL.sub(/\A[a-z-]+:/, "#{scheme}:")
  end

  private def with_public_schemes_claimed(&)
    DB.register_driver "postgres", ListenSchemeRefusingDriver
    DB.register_driver "postgresql", ListenSchemeRefusingDriver
    yield
  ensure
    DB.register_driver "postgres", Grant::PG::Driver
    DB.register_driver "postgresql", Grant::PG::Driver
  end

  private def expect_notification_through(scheme : String)
    channel_name = "d11_#{scheme.gsub('-', '_')}"
    payloads = Channel(String).new(1)
    listener = with_public_schemes_claimed do
      Grant::PG.connect_listen(listen_scheme_url(scheme), channel_name) do |notification|
        payloads.send(notification.payload)
      end
    end
    begin
      DB.open(listen_scheme_url(Grant::PG::Driver::GRANT_ONLY_SCHEME)) do |db|
        db.exec "SELECT pg_notify($1, $2)", channel_name, "hello from #{scheme}"
      end
      select
      when payload = payloads.receive
        payload.should eq "hello from #{scheme}"
      when timeout(5.seconds)
        fail "no notification arrived on #{channel_name}"
      end
    ensure
      listener.close
    end
  end

  describe "Grant::PG connections that bypass the adapter" do
    it "listens through Grant's driver for a postgres:// URL when another driver claims that scheme" do
      expect_notification_through("postgres")
    end

    it "listens through Grant's driver for postgresql:// and grant-postgres:// URLs" do
      expect_notification_through("postgresql")
      expect_notification_through(Grant::PG::Driver::GRANT_ONLY_SCHEME)
    end

    it "opens a replication connection through Grant's driver for a postgres:// URL" do
      replication = with_public_schemes_claimed do
        Grant::PG.connect_replication(listen_scheme_url("postgres"),
          handler: ListenSchemeReplicationHandler.new,
          publication_name: "d11_publication",
          slot_name: "d11_slot",
          keepalive_interval: 1.hour)
      end
      begin
        replication_uri = replication.@uri
        replication_uri.scheme.should eq Grant::PG::Driver::GRANT_ONLY_SCHEME
        replication_uri.query_params["replication"].should eq "database"
      ensure
        replication.close
      end
    end

    it "rewrites only the public PostgreSQL schemes and keeps the rest of the URL" do
      Grant::PG.grant_only_url("postgres://app:secret@db.example:6543/app_db?sslmode=require")
        .should eq "grant-postgres://app:secret@db.example:6543/app_db?sslmode=require"
      Grant::PG.grant_only_url("postgresql://db.example/app_db").should eq "grant-postgres://db.example/app_db"
      Grant::PG.grant_only_url("sqlite3:./app.db").should eq "sqlite3:./app.db"
      Grant::PG.grant_only_url("mysql://db.example/app_db").should eq "mysql://db.example/app_db"
      Grant::PG.grant_only_url("grant-postgres://db.example/app_db").should eq "grant-postgres://db.example/app_db"

      uri = Grant::PG.grant_only_url(URI.parse("postgres://app@db.example:6543/app_db?replication=database"))
      uri.to_s.should eq "grant-postgres://app@db.example:6543/app_db?replication=database"
      mysql_uri = URI.parse("mysql://db.example/app_db")
      Grant::PG.grant_only_url(mysql_uri).should be mysql_uri
    end

    it "closes and refuses a connection that another driver built under Grant's own scheme" do
      ListenSchemeForeignConnection.closed_once = false
      DB.register_driver Grant::PG::Driver::GRANT_ONLY_SCHEME, ListenSchemeForeignDriver
      begin
        expect_raises(Grant::PG::Error, /not a Grant PostgreSQL connection/) do
          Grant::PG.connect_listen(listen_scheme_url("postgres"), "d11_foreign") { }
        end
        ListenSchemeForeignConnection.closed_once?.should be_true
      ensure
        DB.register_driver Grant::PG::Driver::GRANT_ONLY_SCHEME, Grant::PG::Driver
      end
    end
  end
{% end %}
