require "../../spec_helper"
require "../../support/w6_c04_support"
require "../../support/statement_recorder"

# SQLite has no server to restart, so its adapter here fails the idle probe the
# way a dead socket does. PostgreSQL gets the real thing: its backends are
# terminated, as a restart or a failover would.
class W6ProbeSqlite < Grant::Adapter::Sqlite
  property probes : Int32 = 0
  property dead_probes : Int32 = 0

  protected def verify_idle_connection(connection : DB::Connection) : Nil
    @probes += 1
    if @dead_probes > 0
      @dead_probes -= 1
      raise DB::ConnectionLost.new(connection)
    end
    super
  end
end

class W6IdleThing < Grant::Base
  connection "w6_idle"
  table w6_idle_things
  column id : Int64, primary: true
  column label : String?
end

private def w6_idle_adapter(verify_idle_after : Time::Span?) : Grant::Adapter::Base
  Grant::ConnectionRegistry.establish_connection(
    database: "w6_idle", adapter: W6C04.pg? ? Grant::Adapter::Pg : W6ProbeSqlite, url: W6C04.url("w6_idle"),
    role: :primary, pool_size: 3, initial_pool_size: 1, verify_idle_after: verify_idle_after)
  Grant::ConnectionRegistry.get_adapter("w6_idle", :primary)
end

# Makes every idle connection of *adapter* dead: terminates the PostgreSQL
# backends, or arms the SQLite probe to fail once.
private def w6_kill_idle_connections(adapter : Grant::Adapter::Base) : Nil
  if W6C04.pg?
    DB.open(W6C04.pg_url("postgres")) do |db|
      db.exec "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '#{W6C04.database_name("w6_idle")}' AND pid <> pg_backend_pid()"
    end
  else
    adapter.as(W6ProbeSqlite).dead_probes = 1
  end
end

private def w6_probes(adapter : Grant::Adapter::Base) : Int32
  W6C04.pg? ? 0 : adapter.as(W6ProbeSqlite).probes
end

describe "idle connection verification (#{CURRENT_ADAPTER})" do
  before_all do
    W6C04.provision("w6_idle", ["CREATE TABLE w6_idle_things (#{W6C04.id_column}, label TEXT)"])
  end

  after_each { W6C04.remove("w6_idle", :primary) }
  after_all { W6C04.cleanup }

  it "verifies a connection after 30 seconds idle unless told otherwise, and can be turned off" do
    Grant::ConnectionRegistry.establish_connection(database: "w6_idle", adapter: W6C04.adapter_class, url: W6C04.url("w6_idle"), role: :primary)
    Grant::ConnectionRegistry.get_adapter("w6_idle", :primary).verify_idle_after.should eq 30.seconds
    Grant::ConnectionRegistry.connection_spec("w6_idle", :primary).not_nil!.verify_idle_after.should eq 30.seconds
    W6C04.remove("w6_idle", :primary)

    w6_idle_adapter(nil).verify_idle_after.should be_nil
  end

  it "replaces a dead idle connection with one probe instead of failing the write" do
    adapter = w6_idle_adapter(20.milliseconds)
    W6IdleThing.create!(label: "before")
    sleep 40.milliseconds
    w6_kill_idle_connections(adapter)

    W6IdleThing.create!(label: "after the restart").persisted?.should be_true
    W6IdleThing.where(label: "after the restart").count.should eq 1
  end

  it "starts a transaction on a connection that went stale while idle" do
    adapter = w6_idle_adapter(20.milliseconds)
    W6IdleThing.create!(label: "warm")
    sleep 40.milliseconds
    w6_kill_idle_connections(adapter)

    W6IdleThing.transaction { W6IdleThing.create!(label: "inside a transaction") }
    W6IdleThing.where(label: "inside a transaction").count.should eq 1
  end

  it "reads through a dead idle connection" do
    adapter = w6_idle_adapter(20.milliseconds)
    W6IdleThing.create!(label: "readable")
    sleep 40.milliseconds
    w6_kill_idle_connections(adapter)

    W6IdleThing.where(label: "readable").count.should eq 1
  end

  it "keeps the pool within its size when it discards a dead connection" do
    adapter = w6_idle_adapter(20.milliseconds)
    W6IdleThing.create!(label: "pool")
    sleep 40.milliseconds
    w6_kill_idle_connections(adapter)
    W6IdleThing.count

    adapter.pool_stat.connections.should be <= 3
    adapter.pool_stat.busy.should eq 0
  end

  it "never probes connections that are in use" do
    adapter = w6_idle_adapter(10.seconds)
    statements = StatementRecorder.statements do
      200.times { W6IdleThing.count }
    end

    w6_probes(adapter).should eq 0
    statements.count(&.strip.upcase.starts_with?("SELECT 1")).should eq 0
  end

  it "probes once after the idle threshold, not on every checkout" do
    adapter = w6_idle_adapter(30.milliseconds)
    W6IdleThing.count
    sleep 60.milliseconds

    statements = StatementRecorder.statements do
      50.times { W6IdleThing.count }
    end

    probes = statements.count(&.strip.upcase.starts_with?("SELECT 1"))
    (W6C04.pg? ? probes : w6_probes(adapter)).should eq 1
  end

  it "does not retry a write whose connection drops mid-statement" do
    adapter = w6_idle_adapter(nil)
    attempts = 0

    expect_raises(Grant::ConnectionFailed) do
      adapter.open("INSERT INTO w6_idle_things (label) VALUES ('lost')") do |_|
        attempts += 1
        raise DB::ConnectionLost.new(adapter.database.checkout)
      end
    end

    attempts.should eq 1
  end

  if CURRENT_ADAPTER == "pg"
    it "without the probe a dead idle connection still fails one write" do
      adapter = w6_idle_adapter(nil)
      W6IdleThing.create!(label: "warm")
      w6_kill_idle_connections(adapter)

      expect_raises(Grant::ConnectionFailed) { W6IdleThing.create!(label: "unlucky") }
      W6IdleThing.create!(label: "next one works")
      W6IdleThing.where(label: "unlucky").count.should eq 0
    end
  end

  it "rebuilds the pool on reconnect!" do
    adapter = w6_idle_adapter(20.milliseconds)
    W6IdleThing.create!(label: "first")

    adapter.reconnect!

    adapter.connected?.should be_true
    W6IdleThing.where(label: "first").count.should eq 1
  end
end
