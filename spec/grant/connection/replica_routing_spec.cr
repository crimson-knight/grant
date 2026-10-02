require "./pool_spec_support"
require "file_utils"

# Three SQLite files stand in for a writer and two replicas. Each holds a row
# that names it, so what a query returns identifies the adapter Grant chose.
C02_RR_DIR = File.join(Dir.tempdir, "c02_rr_#{Process.pid}")
C02_RR_W   = File.join(C02_RR_DIR, "writer.sqlite3")
C02_RR_A   = File.join(C02_RR_DIR, "reader_a.sqlite3")
C02_RR_B   = File.join(C02_RR_DIR, "reader_b.sqlite3")

class C02RoutedRecord < Grant::Base
  table c02_routed_records
  column id : Int64, primary: true
  column label : String?
  connects_to database: {writing: "c02_rr_writer", reading: "c02_rr_reader"}
end

class C02StrategyRecord < Grant::Base
  table c02_strategy_records
  column id : Int64, primary: true
  configure_connection(load_balancing_strategy: Grant::WeightedStrategy.new)
  connects_to database: {writing: "c02_rr_writer", reading: "c02_rr_strategy"}
end

private def labels_in(path : String) : Array(String)
  labels = [] of String
  DB.open("sqlite3:#{path}") do |db|
    db.query("SELECT label FROM c02_routed_records ORDER BY id") { |rs| rs.each { labels << rs.read(String) } }
  end
  labels
end

private def register_readers : Nil
  Grant::ConnectionRegistry.establish_connection(
    database: "c02_rr_reader", adapter: Grant::Adapter::Sqlite, url: "sqlite3:#{C02_RR_A}", role: :reading, replica_index: 0)
  Grant::ConnectionRegistry.establish_connection(
    database: "c02_rr_reader", adapter: Grant::Adapter::Sqlite, url: "sqlite3:#{C02_RR_B}", role: :reading, replica_index: 1)
end

private def read_label(record_class : C02RoutedRecord.class) : String
  record_class.connected_to(role: :reading) { record_class.first!.label.not_nil! }
end

describe "read replica routing" do
  before_all do
    Dir.mkdir_p(C02_RR_DIR)
    {C02_RR_W => "writer row", C02_RR_A => "reader a row", C02_RR_B => "reader b row"}.each do |path, label|
      File.delete?(path)
      DB.open("sqlite3:#{path}") do |db|
        db.exec "CREATE TABLE c02_routed_records (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT)"
        db.exec "INSERT INTO c02_routed_records (label) VALUES ('#{label}')"
      end
    end
    Grant::ConnectionRegistry.establish_connection(
      database: "c02_rr_writer", adapter: Grant::Adapter::Sqlite, url: "sqlite3:#{C02_RR_W}", role: :writing)
  end

  before_each do
    register_readers
  end

  after_each do
    Grant::ConnectionRegistry.remove_connection("c02_rr_reader", :reading, replica_index: 0)
    Grant::ConnectionRegistry.remove_connection("c02_rr_reader", :reading, replica_index: 1)
  end

  after_all do
    # Remove only this file's connections: clear_all would also drop the
    # default spec connections, and the next file's before_all runs before any
    # before_each can restore them.
    Grant::ConnectionRegistry.remove_connection("c02_rr_writer", :writing)
    Grant::ConnectionRegistry.remove_connection("c02_rr_strategy", :reading)
    FileUtils.rm_rf(C02_RR_DIR)
  end

  it "reads from the replicas and sends writes to the writer only" do
    read_label(C02RoutedRecord).should contain "reader"

    C02RoutedRecord.create!(label: "written")

    labels_in(C02_RR_W).should contain "written"
    labels_in(C02_RR_A).should eq ["reader a row"]
    labels_in(C02_RR_B).should eq ["reader b row"]
  end

  it "keeps both replicas registered under one database and spreads reads across them" do
    balancer = Grant::ConnectionRegistry.get_load_balancer("c02_rr_reader").not_nil!
    balancer.size.should eq 2

    # A model read resolves its adapter more than once, so count picks on the
    # balancer itself to see the rotation.
    picked = Set(String).new
    4.times { picked << balancer.next_replica.not_nil!.url }
    picked.size.should eq 2

    4.times { read_label(C02RoutedRecord).should contain "reader" }
  end

  it "registers a replica idempotently: the same key replaces it and closes the old pool" do
    balancer = Grant::ConnectionRegistry.get_load_balancer("c02_rr_reader").not_nil!
    old = Grant::ConnectionRegistry.get_adapter("c02_rr_reader", :reading)
    old.open(&.scalar("SELECT 1"))
    old_pool = old.database

    register_readers
    register_readers

    balancer.size.should eq 2
    old_pool.pool.stats.open_connections.should eq 0
    Grant::ConnectionRegistry.get_adapter("c02_rr_reader", :reading).same?(old).should be_false
  end

  it "removes a replica from rotation when its connection is removed" do
    Grant::ConnectionRegistry.remove_connection("c02_rr_reader", :reading, replica_index: 1).should be_true

    balancer = Grant::ConnectionRegistry.get_load_balancer("c02_rr_reader").not_nil!
    balancer.size.should eq 1
    4.times { read_label(C02RoutedRecord).should eq "reader a row" }
  end

  it "registers several replicas in one call" do
    Grant::ConnectionRegistry.remove_connection("c02_rr_reader", :reading, replica_index: 0)
    Grant::ConnectionRegistry.remove_connection("c02_rr_reader", :reading, replica_index: 1)

    Grant::ConnectionRegistry.establish_replicas(
      database: "c02_rr_reader", adapter: Grant::Adapter::Sqlite,
      urls: ["sqlite3:#{C02_RR_A}", "sqlite3:#{C02_RR_B}"])

    Grant::ConnectionRegistry.get_load_balancer("c02_rr_reader").not_nil!.size.should eq 2
  end

  describe "least connections" do
    it "sends a read to the replica with fewer connections checked out, and counts them back down" do
      Grant::ConnectionRegistry.load_balancing_strategy("c02_rr_reader", Grant::LeastConnectionsStrategy.new)
      balancer = Grant::ConnectionRegistry.get_load_balancer("c02_rr_reader").not_nil!
      first = balancer.replicas[0]
      second = balancer.replicas[1]

      hold = Channel(Nil).new
      release = Channel(Nil).new
      finished = Channel(Nil).new
      spawn do
        first.open do |_|
          hold.send(nil)
          release.receive
        end
        finished.send(nil)
      end
      hold.receive
      first.active_checkouts.should eq 1

      4.times { balancer.next_replica.not_nil!.same?(second).should be_true }

      release.send(nil)
      finished.receive
      first.active_checkouts.should eq 0
      second.active_checkouts.should eq 0

      # Idle again: both are candidates.
      picked = Set(String).new
      4.times { picked << balancer.next_replica.not_nil!.name }
      picked.size.should eq 2
    end

    it "releases the count when the block raises" do
      adapter = Grant::ConnectionRegistry.get_adapter("c02_rr_reader", :reading)

      expect_raises(Exception, "boom") { adapter.open { |_| raise "boom" } }

      adapter.active_checkouts.should eq 0
    end

    it "picks without allocating" do
      Grant::ConnectionRegistry.load_balancing_strategy("c02_rr_reader", Grant::LeastConnectionsStrategy.new)
      balancer = Grant::ConnectionRegistry.get_load_balancer("c02_rr_reader").not_nil!
      balancer.next_replica

      before = GC.stats.total_bytes
      10_000.times { balancer.next_replica }
      (GC.stats.total_bytes - before).should be < 65_536
    end
  end

  describe "counters" do
    it "keeps rotating when the round-robin and weighted cursors wrap around" do
      round_robin = Grant::RoundRobinStrategy.new
      round_robin.@current_index.set(Int32::MAX - 1)
      picks = Array.new(4) { round_robin.next_index(3) }
      picks.each { |index| (0...3).should contain index }

      weighted = Grant::WeightedStrategy.new
      weighted.@cursor.set(Int32::MAX.to_i64 + 5)
      4.times { (0...3).should contain weighted.next_index(3) }

      least = Grant::LeastConnectionsStrategy.new
      least.@tie_breaker.set(Int32::MAX)
      entries = [Grant::ReplicaEntry.new(Grant::ConnectionRegistry.get_adapter("c02_rr_writer", :writing))]
      least.pick(entries).should_not be_nil
    end
  end

  describe "weighted" do
    it "gives each replica reads in proportion to its weight" do
      Grant::ConnectionRegistry.establish_connection(
        database: "c02_rr_reader", adapter: Grant::Adapter::Sqlite, url: "sqlite3:#{C02_RR_A}",
        role: :reading, replica_index: 0, replica_weight: 3)
      Grant::ConnectionRegistry.load_balancing_strategy("c02_rr_reader", Grant::WeightedStrategy.new)
      balancer = Grant::ConnectionRegistry.get_load_balancer("c02_rr_reader").not_nil!

      counts = Hash(String, Int32).new(0)
      8.times { counts[balancer.next_replica.not_nil!.url.includes?("reader_a") ? "a" : "b"] += 1 }

      counts["a"].should eq 6
      counts["b"].should eq 2
    end
  end

  describe "configure_connection(load_balancing_strategy:)" do
    it "compiles in a model body and applies the strategy to replicas registered afterwards" do
      Grant::ConnectionRegistry.establish_connection(
        database: "c02_rr_strategy", adapter: Grant::Adapter::Sqlite, url: "sqlite3:#{C02_RR_A}", role: :reading)

      Grant::ConnectionRegistry.get_load_balancer("c02_rr_strategy").not_nil!.strategy.should be C02StrategyRecord.load_balancing_strategy.not_nil!
      Grant::ConnectionRegistry.remove_connection("c02_rr_strategy", :reading)
    end

    it "applies a strategy set at runtime to replicas that already exist" do
      strategy = Grant::RandomStrategy.new
      C02RoutedRecord.load_balancing_strategy = strategy

      Grant::ConnectionRegistry.get_load_balancer("c02_rr_reader").not_nil!.strategy.should be strategy
    end
  end
end
