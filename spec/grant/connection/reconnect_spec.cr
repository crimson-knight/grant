require "./pool_spec_support"

# An adapter whose pool refuses the first *refusals* connection attempts, like
# a database that is restarting.
class C02RefusingAdapter < Grant::Adapter::Sqlite
  property refusals : Int32 = 0
  getter attempts : Int32 = 0

  def database : DB::Database
    @attempts += 1
    if @refusals > 0
      @refusals -= 1
      raise DB::ConnectionRefused.new
    end
    super
  end
end

private def pooled_adapter(**options) : Grant::Adapter::Base
  C02Support.establish("c02_reconnect", :writing, **options)
end

# Raises the error crystal-db raises when a connection drops mid-statement.
private def drop_connection(adapter : Grant::Adapter::Base) : NoReturn
  other = adapter.database.checkout
  raise DB::ConnectionLost.new(other)
end

describe "reconnection and retries" do
  after_each do
    Grant::ConnectionRegistry.clear_all
  end

  after_all { C02Support.cleanup }

  it "retries a plain read once after the connection drops" do
    adapter = pooled_adapter(retry_delay: 1.millisecond)
    attempts = 0

    value = adapter.open("SELECT 1") do |connection|
      attempts += 1
      drop_connection(adapter) if attempts == 1
      connection.scalar("SELECT 1")
    end

    value.should eq 1
    attempts.should eq 2
  end

  it "retries a read at most once" do
    adapter = pooled_adapter(retry_attempts: 5, retry_delay: 1.millisecond)
    attempts = 0

    expect_raises(Grant::ConnectionFailed) do
      adapter.open("SELECT 1") do |_|
        attempts += 1
        drop_connection(adapter)
      end
    end
    attempts.should eq 2
  end

  it "never retries a write" do
    adapter = pooled_adapter(retry_delay: 1.millisecond)
    attempts = 0

    error = expect_raises(Grant::ConnectionFailed) do
      adapter.open("INSERT INTO nothing VALUES (1)") do |_|
        attempts += 1
        drop_connection(adapter)
      end
    end

    attempts.should eq 1
    error.cause.should be_a(DB::ConnectionLost)
  end

  it "never retries a call that carries no SQL, or a WITH statement that may write" do
    adapter = pooled_adapter(retry_delay: 1.millisecond)
    attempts = 0

    expect_raises(Grant::ConnectionFailed) do
      adapter.open do |_|
        attempts += 1
        drop_connection(adapter)
      end
    end
    expect_raises(Grant::ConnectionFailed) do
      adapter.open("WITH gone AS (DELETE FROM t RETURNING *) SELECT * FROM gone") do |_|
        attempts += 1
        drop_connection(adapter)
      end
    end
    attempts.should eq 2
  end

  it "does not retry a read inside a transaction" do
    adapter = pooled_adapter(retry_delay: 1.millisecond)
    attempts = 0

    expect_raises(Grant::ConnectionFailed) do
      Grant::Transaction.run(adapter, Grant::Transaction::Options.new) do
        adapter.open("SELECT 1") do |_|
          attempts += 1
          drop_connection(adapter)
        end
      end
    end
    attempts.should eq 1
  end

  it "classifies statements" do
    reads = ["SELECT 1", "  select * from t", "\nSHOW server_version", "EXPLAIN SELECT 1", "VALUES (1)"]
    others = ["INSERT INTO t VALUES (1)", "UPDATE t SET a = 1", "DELETE FROM t", "WITH x AS (SELECT 1) SELECT * FROM x",
              "EXPLAIN ANALYZE DELETE FROM t", "SET search_path TO x", "", "   "]
    reads.each { |sql| Grant::Adapter::PoolSupport.idempotent_read?(sql).should be_true }
    others.each { |sql| Grant::Adapter::PoolSupport.idempotent_read?(sql).should be_false }
    Grant::Adapter::PoolSupport.idempotent_read?(nil).should be_false
  end

  it "backs off exponentially up to a cap" do
    base = 100.milliseconds
    Grant::Adapter::PoolSupport.backoff(base, 0).should eq 100.milliseconds
    Grant::Adapter::PoolSupport.backoff(base, 1).should eq 200.milliseconds
    Grant::Adapter::PoolSupport.backoff(base, 3).should eq 800.milliseconds
    Grant::Adapter::PoolSupport.backoff(base, 30).should eq Grant::Adapter::PoolSupport::MAX_BACKOFF
  end

  describe "connect failures" do
    it "retries a refused connection up to retry_attempts and then succeeds" do
      adapter = C02RefusingAdapter.new("c02_refusing", C02Support.url("c02_refusing"))
      adapter.retry_attempts = 2
      adapter.retry_delay = 1.millisecond
      adapter.refusals = 2

      adapter.open("INSERT INTO t VALUES (1)") { |connection| connection.scalar("SELECT 1") }.should eq 1
      adapter.attempts.should eq 3
    end

    it "raises Grant::ConnectionFailed when the database stays down" do
      adapter = C02RefusingAdapter.new("c02_refusing", C02Support.url("c02_refusing"))
      adapter.retry_attempts = 2
      adapter.retry_delay = 1.millisecond
      adapter.refusals = 10

      error = expect_raises(Grant::ConnectionFailed) { adapter.open { |connection| connection.scalar("SELECT 1") } }
      error.cause.should be_a(DB::ConnectionRefused)
      adapter.attempts.should eq 3
    end

    it "counts a fiber backing off between attempts as waiting" do
      adapter = C02RefusingAdapter.new("c02_refusing", C02Support.url("c02_refusing"))
      adapter.retry_attempts = 3
      adapter.retry_delay = 30.milliseconds
      adapter.refusals = 2

      finished = Channel(Nil).new
      spawn do
        adapter.open { |connection| connection.scalar("SELECT 1") }
        finished.send(nil)
      end
      Fiber.yield
      adapter.pool_stat.waiting.should eq 1
      finished.receive
      adapter.pool_stat.waiting.should eq 0
    end
  end

  describe "liveness" do
    it "answers active? and verify! for a reachable database" do
      adapter = pooled_adapter
      adapter.active?.should be_true
      adapter.verify!
    end

    it "raises Grant::ConnectionFailed from verify! and answers false from active? when unreachable" do
      adapter = C02Support.adapter_class.new("c02_unreachable", C02Support.unreachable_url)
      adapter.retry_attempts = 0

      adapter.active?.should be_false
      expect_raises(Grant::ConnectionFailed) { adapter.verify! }
    end

    it "reconnect! replaces the pool and the old one is closed" do
      adapter = pooled_adapter
      adapter.open { |connection| connection.scalar("SELECT 1") }
      old_pool = adapter.database

      adapter.reconnect!

      old_pool.pool.stats.open_connections.should eq 0
      adapter.database.same?(old_pool).should be_false
      adapter.open { |connection| connection.scalar("SELECT 1") }.should eq 1
    end
  end
end
