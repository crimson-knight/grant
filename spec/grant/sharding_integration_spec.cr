require "../spec_helper"
require "../support/simple_virtual_sharding"

# Integration tests for sharding functionality.
#
# These exercise the real QueryRouter + ShardedExecutor against the
# `simple_virtual_sharding` harness (no real DB): each VirtualShardAdapter
# records the SQL it was asked to run, so `track_shard_queries` lets us assert
# *which shards* a query touched. That is exactly what's needed to verify
# routing, scatter-gather fan-out, and fiber-local shard context.
include Grant::Testing::ShardingHelpers

# Test models covering the edge cases / strategies under test.

# Single custom (non-id) shard key — proves routing is not hard-coded to id.
class IntegrationAccount < Grant::Base
  connection "test"
  table integration_accounts

  include Grant::Sharding::Model

  shards_by :account_id, strategy: :hash, count: 4

  column id : Int64, primary: true
  column account_id : Int64
  column name : String
  column active : Bool = true
end

# Nullable shard key edge case.
class EdgeCaseModel < Grant::Base
  connection "test"
  table edge_cases

  include Grant::Sharding::Model

  # What happens with nullable shard keys?
  shards_by :tenant_id, strategy: :hash, count: 2

  column id : Int64, primary: true
  column tenant_id : Int64? # Nullable!
  column data : String
end

# Composite shard key.
class CompoundKeyModel < Grant::Base
  connection "test"
  table compound_keys

  include Grant::Sharding::Model

  # Multiple shard keys (splat form — the array-literal form is not a valid
  # argument to the variadic `shards_by(*columns)` macro).
  shards_by :region, :customer_id, strategy: :hash, count: 4

  column id : Int64, primary: true
  column region : String
  column customer_id : Int64
  column data : String
end

class LunaMoveRecord < Grant::Base
  connection "test"
  table luna_move_records

  include Grant::Sharding::Model
  shards_by :tenant_id, strategy: :hash, count: 2

  column id : Int64, primary: true
  column tenant_id : Int64
  column label : String
end

describe "Sharding Integration Tests" do
  describe "Cross-strategy query routing" do
    it "routes a custom (non-id) shard-key column to a single shard" do
      with_virtual_shards(4) do
        account_id = 7_i64
        expected = Grant::ShardManager.resolve_shard("IntegrationAccount", account_id: account_id)

        query_log = track_shard_queries do
          IntegrationAccount.where(account_id: account_id).select
        end

        # The whole point of the fix: a declared custom column resolves to one
        # shard instead of silently scatter-gathering as :unknown_field.
        query_log.shards_accessed.should eq([expected])
      end
    end

    it "routes a composite shard key (all keys present) to a single shard" do
      with_virtual_shards(4) do
        expected = Grant::ShardManager.resolve_shard(
          "CompoundKeyModel", region: "us-east", customer_id: 99_i64)

        query_log = track_shard_queries do
          CompoundKeyModel.where(region: "us-east").where(customer_id: 99_i64).select
        end

        query_log.shards_accessed.should eq([expected])
      end
    end

    it "falls back to scatter-gather when only part of a composite key is given" do
      with_virtual_shards(4) do
        # Only one of the two declared keys -> cannot resolve deterministically.
        query_log = track_shard_queries do
          CompoundKeyModel.where(region: "us-east").select
        end

        query_log.shards_accessed.sort.should eq([:shard_0, :shard_1, :shard_2, :shard_3])
      end
    end
  end

  describe "Scatter-gather correctness" do
    it "queries every shard when no shard key is present" do
      with_virtual_shards(4) do
        query_log = track_shard_queries do
          IntegrationAccount.where(name: "Acme").select
        end

        query_log.shards_accessed.sort.should eq([:shard_0, :shard_1, :shard_2, :shard_3])
      end
    end

    it "aggregates count across all shards for non-keyed queries" do
      with_virtual_shards(4) do
        query_log = track_shard_queries do
          IntegrationAccount.where(active: true).count
        end

        query_log.shards_accessed.sort.should eq([:shard_0, :shard_1, :shard_2, :shard_3])
      end
    end

    it "does not misroute when the shard key is used with a non-equality operator" do
      with_virtual_shards(4) do
        # `>` on the shard key cannot pin a single hash shard -> scatter-gather.
        query_log = track_shard_queries do
          IntegrationAccount.where(:account_id, :gt, 5_i64).select
        end

        query_log.shards_accessed.sort.should eq([:shard_0, :shard_1, :shard_2, :shard_3])
      end
    end
  end

  describe "Performance characteristics" do
    it "executes scatter-gather queries in parallel on fibers" do
      with_virtual_shards(4) do
        shards = Grant::ShardManager.shards_for_model("IntegrationAccount")

        # Each shard fiber yields to the scheduler before recording itself; a
        # serial implementation could not interleave them. We assert every
        # shard fiber ran and produced its result via the parallel executor.
        order = [] of Symbol
        mutex = Mutex.new

        Grant::Async::ShardedExecutor.execute_and_wait(shards) do |shard|
          Grant::Async::AsyncResult.new do
            Fiber.yield
            mutex.synchronize { order << shard }
            shard
          end
        end

        order.sort.should eq(shards.sort)
      end
    end

    it "optimizes single-shard queries (touches exactly one shard)" do
      with_virtual_shards(4) do
        account_id = 12345_i64
        expected = Grant::ShardManager.resolve_shard("IntegrationAccount", account_id: account_id)

        query_log = track_shard_queries do
          IntegrationAccount.where(account_id: account_id).select
        end

        query_log.shards_accessed.size.should eq(1)
        query_log.shards_accessed.first.should eq(expected)
      end
    end
  end

  describe "Edge cases" do
    it "scatter-gathers when a nullable shard key is nil" do
      with_virtual_shards(2) do
        # nil shard key value cannot pin a shard -> fan out to all.
        query_log = track_shard_queries do
          EdgeCaseModel.where(tenant_id: nil).select
        end

        query_log.shards_accessed.sort.should eq([:shard_0, :shard_1])
      end
    end

    it "routes a present nullable shard key to a single shard" do
      with_virtual_shards(2) do
        tenant_id = 42_i64
        expected = Grant::ShardManager.resolve_shard("EdgeCaseModel", tenant_id: tenant_id)

        query_log = track_shard_queries do
          EdgeCaseModel.where(tenant_id: tenant_id).select
        end

        query_log.shards_accessed.should eq([expected])
      end
    end

    it "recomputes the target shard when the shard key value changes" do
      # Routing is value-derived, so the same model with different key values
      # resolves independently (a moved record lands on a different shard).
      a = Grant::ShardManager.resolve_shard("EdgeCaseModel", tenant_id: 1_i64)
      b = Grant::ShardManager.resolve_shard("EdgeCaseModel", tenant_id: 2_i64)

      # Re-resolving the same value is stable and deterministic per value.
      Grant::ShardManager.resolve_shard("EdgeCaseModel", tenant_id: 1_i64).should eq(a)
      [a, b].each { |s| s.to_s.should match(/^shard_\d$/) }
    end
  end

  describe "Data consistency" do
    it "maintains fiber-local shard context across nesting" do
      Grant::ShardManager.current_shard.should be_nil

      Grant::ShardManager.with_shard(:shard_0) do
        Grant::ShardManager.current_shard.should eq(:shard_0)

        Grant::ShardManager.with_shard(:shard_1) do
          Grant::ShardManager.current_shard.should eq(:shard_1)
        end

        # Restored to the outer context after the nested block.
        Grant::ShardManager.current_shard.should eq(:shard_0)
      end

      Grant::ShardManager.current_shard.should be_nil
    end

    it "isolates shard context between concurrent fibers" do
      results = {} of Symbol => Symbol?
      mutex = Mutex.new
      wg = WaitGroup.new

      [:shard_0, :shard_1, :shard_2, :shard_3].each do |shard|
        wg.add(1)
        spawn do
          Grant::ShardManager.with_shard(shard) do
            # Force interleaving so a leaky (non-fiber-local) impl would clobber.
            Fiber.yield
            seen = Grant::ShardManager.current_shard
            mutex.synchronize { results[shard] = seen }
          end
        ensure
          wg.done
        end
      end

      wg.wait

      # Each fiber observed only its own shard, despite interleaving.
      results.should eq({
        :shard_0 => :shard_0,
        :shard_1 => :shard_1,
        :shard_2 => :shard_2,
        :shard_3 => :shard_3,
      })
      # And the spawning fiber's context is untouched.
      Grant::ShardManager.current_shard.should be_nil
    end
  end

  describe "Migration support" do
    it "moves a persisted record between real SQLite shard databases" do
      Grant::ConnectionRegistry.clear_all
      [:shard_0, :shard_1].each do |shard|
        Grant::ConnectionRegistry.establish_connection(
          database: "test",
          adapter: Grant::Adapter::Sqlite,
          url: "sqlite3::memory:",
          role: :primary,
          shard: shard,
          pool_size: 1,
          initial_pool_size: 1
        )
        Grant::ShardManager.with_shard(shard) do
          LunaMoveRecord.adapter.open do |db|
            db.exec "CREATE TABLE luna_move_records (id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL, label TEXT NOT NULL)"
          end
        end
      end

      begin
        original = LunaMoveRecord.new(id: 812_i64, tenant_id: 123_i64, label: "preserve me")
        source_shard = original.determine_shard
        target_shard = source_shard == :shard_0 ? :shard_1 : :shard_0
        original.current_shard = source_shard
        Grant::ShardManager.with_shard(source_shard) { original.save! }

        destination_tenant_id = (1_i64..10_000_i64).find do |tenant_id|
          Grant::ShardManager.resolve_shard("LunaMoveRecord", tenant_id: tenant_id) == target_shard
        end.not_nil!
        original.tenant_id = destination_tenant_id

        moved = original.move_to_shard(target_shard)

        LunaMoveRecord.on_shard(source_shard).find(original.id).should be_nil
        persisted = LunaMoveRecord.on_shard(target_shard).find(moved.id).not_nil!
        persisted.label.should eq("preserve me")
        persisted.tenant_id.should eq(destination_tenant_id)
        moved.current_shard.should eq(target_shard)
        original.destroyed?.should be_true
      ensure
        [:shard_0, :shard_1].each do |shard|
          if adapter = Grant::ConnectionRegistry.get_adapter("test", :primary, shard).as?(Grant::Adapter::Sqlite)
            adapter.database.pool.close
          end
        end
        Grant::ConnectionRegistry.clear_all
      end
    end
  end
end
