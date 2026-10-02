require "../connection_context"

module Grant
  class ShardManager
    # Thread-safe storage for shard configurations
    @@shard_configs = {} of String => Sharding::ShardConfig
    @@mutex = Mutex.new

    # Register shard configuration for a model
    def self.register(model_name : String, config : Sharding::ShardConfig)
      @@mutex.synchronize do
        @@shard_configs[model_name] = config
      end
    end

    # Runs the block with *shard* as the active shard of this fiber, so every
    # sharded model reaches that shard's database. This is an explicit shard
    # swap: it raises `Grant::ShardSwappingProhibited` while
    # `prohibit_shard_swapping` is active. Grant's own routing (a record going
    # to the shard its key resolves to, a query fanning out over its shards)
    # uses `route_to`, which the prohibition does not cover.
    def self.with_shard(shard : Symbol, &)
      guard_shard_swap!(shard)
      route_to(shard) { yield }
    end

    # Raises `Grant::ShardSwappingProhibited` when the current fiber is inside
    # `prohibit_shard_swapping`. *shard* names the target in the message.
    #
    # :nodoc:
    def self.guard_shard_swap!(shard : Symbol? = nil) : Nil
      return unless state = ConnectionState.current?
      return unless state.shard_swapping_prohibited?

      target = shard ? " to shard #{shard.inspect}" : ""
      raise Grant::ShardSwappingProhibited.new(
        "Cannot switch#{target} while shard swapping is prohibited")
    end

    # Runs the block with *shard* active without the shard-swapping check:
    # routing Grant does on the data's behalf. The pinned shard lives in the
    # fiber's `ConnectionState`, so no lock is taken per query.
    #
    # :nodoc:
    def self.route_to(shard : Symbol, &)
      state = ConnectionState.current
      previous = state.pinned_shard
      state.pinned_shard = shard
      begin
        yield
      ensure
        state.pinned_shard = previous
      end
    end

    # The shard active for this fiber, or `nil`.
    def self.current_shard : Symbol?
      return nil unless state = ConnectionState.current?

      state.pinned_shard
    end

    # Pins the current fiber to *shard* (or clears it with `nil`) until changed
    # again. Prefer `with_shard`, which restores the previous shard.
    def self.set_current_shard(shard : Symbol?)
      ConnectionState.current.pinned_shard = shard
    end

    # Resolve shard for given keys
    def self.resolve_shard(model_name : String, **keys) : Symbol
      config = @@mutex.synchronize do
        @@shard_configs[model_name]?
      end

      config || raise "No shard configuration for #{model_name}"
      config.resolver.resolve_for_keys(**keys)
    end

    # Get all shards for a model
    def self.shards_for_model(model_name : String) : Array(Symbol)
      config = @@mutex.synchronize do
        @@shard_configs[model_name]?
      end

      config || raise "No shard configuration for #{model_name}"
      config.resolver.all_shards.uniq
    end

    # Check if a model is sharded
    def self.sharded?(model_name : String) : Bool
      @@mutex.synchronize do
        @@shard_configs.has_key?(model_name)
      end
    end

    # Get shard configuration for a model
    def self.shard_config(model_name : String) : Sharding::ShardConfig?
      @@mutex.synchronize do
        @@shard_configs[model_name]?
      end
    end

    # Execute on specific shard with connection management
    def self.on_shard(shard : Symbol, database : String, role : Symbol = :primary, &block)
      with_shard(shard) do
        ConnectionRegistry.with_adapter(database, role, shard) do |adapter|
          yield adapter
        end
      end
    end

    # Execute on all shards for a model
    def self.on_all_shards(model_name : String, database : String, role : Symbol = :primary, &block : Symbol, Adapter::Base -> T) forall T
      shards = shards_for_model(model_name)
      results = {} of Symbol => T

      shards.each do |shard|
        results[shard] = on_shard(shard, database, role) do |adapter|
          yield shard, adapter
        end
      end

      results
    end

    # Clear all configurations (mainly for testing)
    def self.clear
      @@mutex.synchronize do
        @@shard_configs.clear
      end
      set_current_shard(nil)
    end

    # Get statistics about shard distribution
    def self.shard_statistics : Hash(String, NamedTuple(model: String, shards: Array(Symbol), shard_count: Int32))
      @@mutex.synchronize do
        stats = {} of String => NamedTuple(model: String, shards: Array(Symbol), shard_count: Int32)

        @@shard_configs.each do |model_name, config|
          shards = config.resolver.all_shards
          stats[model_name] = {
            model:       model_name,
            shards:      shards,
            shard_count: shards.size,
          }
        end

        stats
      end
    end
  end
end
