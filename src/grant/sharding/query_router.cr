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
      shards = shards_for(query)

      if shards.size == 1 && resolve_single_shard(extract_shard_keys(query))
        # All shard keys present and resolvable -> target one shard.
        SingleShardExecution(Model).new(@model, query, shards.first)
      else
        ScatterGatherExecution(Model).new(@model, query, shards)
      end
    end

    # The shards *query* has to visit: the one its shard key pins, the ones a
    # range predicate on the key intersects, or every shard of the model.
    def shards_for(query : Query::Builder(Model)) : Array(Symbol)
      if single_shard = resolve_single_shard(extract_shard_keys(query))
        [single_shard]
      else
        resolve_range_shards(query) || Grant::ShardManager.shards_for_model(@model.name)
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

    # Route a simple inclusive range predicate to the configured shards it
    # intersects. Unknown SQL shapes and OR conditions retain scatter-gather.
    private def resolve_range_shards(query : Query::Builder(Model)) : Array(Symbol)?
      resolver = @shard_config.resolver.as?(RangeResolver)
      return nil unless resolver
      key_name = @shard_config.key_column_names.first?
      return nil unless key_name
      return nil if query.where_fields.any? { |condition| condition[:join] != :and }

      minimum = nil.as(Grant::Columns::Type?)
      maximum = nil.as(Grant::Columns::Type?)
      query.where_fields.each do |condition|
        case condition
        when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
          next unless condition[:field] == key_name
          case condition[:operator]
          when :gt, :gteq
            minimum = condition[:value]
          when :lt, :lteq
            maximum = condition[:value]
          end
        when NamedTuple(join: Symbol, stmt: String, values: Array(Grant::Columns::Type))
          match = condition[:stmt].match(/^\s*["`]?([a-zA-Z_][a-zA-Z0-9_]*)["`]?\s*>=\s*\?\s+AND\s+["`]?([a-zA-Z_][a-zA-Z0-9_]*)["`]?\s*<=\s*\?\s*$/i)
          if match && match[1] == key_name && match[2] == key_name && condition[:values].size == 2
            minimum = condition[:values][0]
            maximum = condition[:values][1]
          end
        end
      end

      low = minimum
      high = maximum
      return nil unless low && high
      return nil unless low.is_a?(String) || low.is_a?(Int64)
      return nil unless high.is_a?(String) || high.is_a?(Int64)
      resolver.shards_for_range(low, high)
    end
  end

  # Base class for query execution strategies
  abstract class QueryExecution(Model)
    abstract def execute : Array(Model)
    abstract def count : Grant::Query::Builder::CountResult
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

    def count : Grant::Query::Builder::CountResult
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

    def count : Grant::Query::Builder::CountResult
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
