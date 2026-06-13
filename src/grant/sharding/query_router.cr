require "../async/sharded_executor"
require "../query/builder"

module Grant::Sharding
  # Routes queries to appropriate shards based on shard keys
  class QueryRouter(Model)
    getter shard_config : ShardConfig

    def initialize(@model : Model.class, @shard_config : ShardConfig)
    end

    # Route query to appropriate shard(s).
    #
    # Routing is resolved entirely by *string* lookup of the model's declared
    # shard-key columns against the query's `where` fields — there is no
    # hard-coded column->symbol mapping, so any declared shard key
    # (`account_id`, composite `[:region, :customer_id]`, etc.) routes
    # correctly. If the query does not pin every declared shard key with an
    # equality condition, we fall back to scatter-gather rather than risk
    # misrouting.
    def route(query : Query::Builder(Model)) : QueryExecution
      shard_keys = extract_shard_keys(query)

      if single_shard = resolve_single_shard(shard_keys)
        # All shard keys present and resolvable -> target one shard.
        SingleShardExecution(Model).new(@model, query, single_shard)
      else
        # Missing/partial/unresolvable shard keys -> scatter-gather across all
        # shards. Correct (if less efficient) regardless of the where clause.
        all_shards = Grant::ShardManager.shards_for_model(@model.name)
        ScatterGatherExecution(Model).new(@model, query, all_shards)
      end
    end

    # Extract equality conditions on declared shard-key columns, keyed by the
    # column-name string. Only `:eq` conditions are usable for point routing;
    # ranges/other operators are ignored (handled by scatter-gather).
    private def extract_shard_keys(query : Query::Builder(Model)) : Hash(String, Grant::Columns::Type)
      keys = {} of String => Grant::Columns::Type

      query.where_fields.each do |condition|
        case condition
        when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
          field = condition[:field]
          if condition[:operator] == :eq && @shard_config.shard_key?(field)
            keys[field] = condition[:value]
          end
        else
          # Statement-based conditions carry no structured field; skip them.
        end
      end

      keys
    end

    # Resolve to a single shard *only* when every declared shard-key column is
    # pinned by an equality condition. Values are assembled in the declared
    # key order and handed to the resolver's value-based API, which works for
    # every resolver type (hash, range, geo, lookup) and any column name.
    private def resolve_single_shard(shard_keys : Hash(String, Grant::Columns::Type)) : Symbol?
      return nil if shard_keys.empty?

      key_names = @shard_config.key_column_names
      # Need all declared keys present to resolve deterministically.
      return nil unless key_names.all? { |name| shard_keys.has_key?(name) }

      values = key_names.map { |name| shard_keys[name] }

      # A nil shard-key value can't pin a shard (it's `WHERE col IS NULL`, not a
      # routable point lookup) — fall back to scatter-gather rather than hashing
      # nil to an arbitrary shard.
      return nil if values.any?(&.nil?)

      begin
        @shard_config.resolver.resolve_for_values(values)
      rescue
        # Value not resolvable (e.g. out of all defined ranges) -> let the
        # caller fall back to scatter-gather instead of misrouting.
        nil
      end
    end
  end

  # Base class for query execution strategies
  abstract class QueryExecution(Model)
    abstract def execute : Array(Model)
    abstract def count : Int64
    abstract def exists? : Bool
    abstract def pluck(column : String | Symbol) : Array(Grant::Columns::Type)
  end

  # Execute query on a single shard
  class SingleShardExecution(Model) < QueryExecution(Model)
    @query : Grant::Query::Builder(Model)
    @shard : Symbol

    def initialize(@model : Model.class, query : Grant::Query::Builder(Model), @shard : Symbol)
      @query = query
    end

    def execute : Array(Model)
      Grant::ShardManager.with_shard(@shard) do
        # Always use the non-routing method to avoid infinite recursion
        @query.as(Grant::Sharding::ShardedQueryBuilder(Model)).select_without_routing
      end
    end

    def count : Int64
      Grant::ShardManager.with_shard(@shard) do
        # Always use the non-routing method to avoid infinite recursion
        @query.as(Grant::Sharding::ShardedQueryBuilder(Model)).count_without_routing
      end
    end

    def exists? : Bool
      Grant::ShardManager.with_shard(@shard) do
        # Always use the non-routing method to avoid infinite recursion
        @query.as(Grant::Sharding::ShardedQueryBuilder(Model)).exists_without_routing
      end
    end

    def pluck(column : String | Symbol) : Array(Grant::Columns::Type)
      Grant::ShardManager.with_shard(@shard) do
        # Always use the non-routing method to avoid infinite recursion
        @query.as(Grant::Sharding::ShardedQueryBuilder(Model)).pluck_without_routing(column)
      end
    end
  end

  # Execute query across all shards (scatter-gather)
  class ScatterGatherExecution(Model) < QueryExecution(Model)
    @query : Grant::Query::Builder(Model)
    @shards : Array(Symbol)

    def initialize(@model : Model.class, query : Grant::Query::Builder(Model), @shards : Array(Symbol))
      @query = query
    end

    def execute : Array(Model)
      # Use async executor for parallel execution
      results = Grant::Async::ShardedExecutor.execute_and_wait(@shards) do |shard|
        Grant::Async::AsyncResult.new do
          Grant::ShardManager.with_shard(shard) do
            # Always use the non-routing method to avoid infinite recursion
            @query.as(Grant::Sharding::ShardedQueryBuilder(Model)).select_without_routing
          end
        end
      end

      # Merge and sort results
      merge_results(results.values)
    end

    def count : Int64
      results = Grant::Async::ShardedExecutor.execute_and_aggregate(@shards) do |shard|
        Grant::Async::AsyncResult.new do
          Grant::ShardManager.with_shard(shard) do
            # Always use the non-routing method to avoid infinite recursion
            @query.as(Grant::Sharding::ShardedQueryBuilder(Model)).count_without_routing
          end
        end
      end

      results.as(Int64)
    end

    def exists? : Bool
      # Short-circuit on first true result
      @shards.each do |shard|
        Grant::ShardManager.with_shard(shard) do
          # Always use the non-routing method to avoid infinite recursion
          return true if @query.as(Grant::Sharding::ShardedQueryBuilder(Model)).exists_without_routing
        end
      end
      false
    end

    def pluck(column : String | Symbol) : Array(Grant::Columns::Type)
      results = Grant::Async::ShardedExecutor.execute_and_wait(@shards) do |shard|
        Grant::Async::AsyncResult.new do
          Grant::ShardManager.with_shard(shard) do
            # Always use the non-routing method to avoid infinite recursion
            @query.as(Grant::Sharding::ShardedQueryBuilder(Model)).pluck_without_routing(column)
          end
        end
      end

      # Flatten all plucked values
      results.values.flatten
    end

    private def merge_results(shard_results : Array(Array(Model))) : Array(Model)
      merged = shard_results.flatten

      # Apply any ORDER BY from original query
      if !@query.order_fields.empty?
        order_fields = @query.order_fields
        merged.sort! do |a, b|
          compare_by_order_fields(a, b, order_fields)
        end
      end

      # Apply LIMIT if present
      if limit = @query.limit
        merged = merged.first(limit)
      end

      merged
    end

    private def compare_by_order_fields(a : Model, b : Model, order_fields : Array(NamedTuple(field: String, direction: Grant::Query::Builder::Sort))) : Int32
      order_fields.each do |order|
        field = order[:field]
        direction = order[:direction]

        val_a = a.read_attribute(field)
        val_b = b.read_attribute(field)

        # Handle nil values
        if val_a.nil? && val_b.nil?
          next
        elsif val_a.nil?
          return direction == Grant::Query::Builder::Sort::Ascending ? -1 : 1
        elsif val_b.nil?
          return direction == Grant::Query::Builder::Sort::Ascending ? 1 : -1
        end

        # Compare values
        comparison = if val_a.is_a?(Number) && val_b.is_a?(Number)
                       val_a <=> val_b
                     elsif val_a.is_a?(String) && val_b.is_a?(String)
                       val_a <=> val_b
                     elsif val_a.is_a?(Time) && val_b.is_a?(Time)
                       val_a <=> val_b
                     else
                       val_a.to_s <=> val_b.to_s
                     end

        # The spaceship operator always returns Int32 when comparing non-nil values
        comparison = comparison.as(Int32)

        # Apply direction
        if direction == Grant::Query::Builder::Sort::Descending
          comparison = -comparison
        end

        return comparison if comparison != 0
      end

      0 # Equal
    end
  end

  # Execute query on multiple specific shards
  class MultiShardExecution(Model) < QueryExecution(Model)
    @query : Grant::Query::Builder(Model)
    @shards : Array(Symbol)

    def initialize(@model : Model.class, query : Grant::Query::Builder(Model), @shards : Array(Symbol))
      @query = query
    end

    # Delegate to ScatterGatherExecution since logic is the same
    def execute : Array(Model)
      ScatterGatherExecution(Model).new(@model, @query, @shards).execute
    end

    def count : Int64
      ScatterGatherExecution(Model).new(@model, @query, @shards).count
    end

    def exists? : Bool
      ScatterGatherExecution(Model).new(@model, @query, @shards).exists?
    end

    def pluck(column : String | Symbol) : Array(Grant::Columns::Type)
      ScatterGatherExecution(Model).new(@model, @query, @shards).pluck(column)
    end
  end
end
