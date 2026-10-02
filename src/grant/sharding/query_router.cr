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
      return if shard_keys.empty?

      key_names = @shard_config.key_column_names
      # Need all declared keys present to resolve deterministically.
      return unless key_names.all? { |name| shard_keys.has_key?(name) }

      values = key_names.map { |name| shard_keys[name] }

      # A nil shard-key value can't pin a shard (it's `WHERE col IS NULL`, not a
      # routable point lookup) — fall back to scatter-gather rather than hashing
      # nil to an arbitrary shard.
      return if values.any?(Nil)

      begin
        @shard_config.resolver.resolve_for_values(values)
      rescue
        # Value not resolvable (e.g. out of all defined ranges) -> let the
        # caller fall back to scatter-gather instead of misrouting.
        nil
      end
    end

    # Prunes the shards a `where` on the first shard-key column can reach:
    # `>=`, `>`, `<=`, `<` (alone or together), a `Range` (inclusive or
    # exclusive, begin- or endless), `BETWEEN`, and the `>= ? AND <= ?` form.
    # `Time`, `Int64` and `String` bounds are understood, as are composite-ID
    # strings with or without a prefix. Each conjunct is resolved on its own and
    # the answers are intersected, which only ever keeps a superset of the shards
    # that hold matching rows. An OR, raw SQL it does not recognize, or bounds
    # the resolver cannot compare returns nil, and the query visits every
    # shard. The query is read once; nothing here runs per row.
    private def resolve_range_shards(query : Query::Builder(Model)) : Array(Symbol)?
      resolver = @shard_config.resolver.as?(RangeResolver)
      return unless resolver
      key_name = @shard_config.key_column_names.first?
      return unless key_name
      return if query.where_fields.any? { |condition| condition[:join] != :and }

      pruned = nil.as(Array(Symbol)?)
      query.where_fields.each do |condition|
        bounds = key_bounds(condition, key_name)
        next unless bounds

        shards = resolver.shards_for_bounds(bounds[:minimum], bounds[:maximum], bounds[:upper_exclusive])
        next unless shards

        pruned = pruned ? pruned & shards : shards
      end
      pruned
    end

    alias KeyBounds = NamedTuple(minimum: Grant::Columns::Type, maximum: Grant::Columns::Type, upper_exclusive: Bool)

    BOUND_COLUMN      = %q(["`]?([a-zA-Z_][a-zA-Z0-9_]*)["`]?)
    PAIR_STATEMENT    = /\A\s*#{BOUND_COLUMN}\s*>=\s*\?\s+AND\s+#{BOUND_COLUMN}\s*(<=|<)\s*\?\s*\z/i
    BETWEEN_STATEMENT = /\A\s*#{BOUND_COLUMN}\s+BETWEEN\s+\?\s+AND\s+\?\s*\z/i

    # The interval one `where` condition puts on *key_name*, or nil when it
    # says nothing the router can use.
    private def key_bounds(condition : Query::Builder::WhereField, key_name : String) : KeyBounds?
      case condition
      when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
        return unless condition[:field] == key_name
        value = condition[:value]
        case condition[:operator]
        when :gt, :gteq then {minimum: value, maximum: nil, upper_exclusive: false}
        when :lteq      then {minimum: nil, maximum: value, upper_exclusive: false}
        when :lt        then {minimum: nil, maximum: value, upper_exclusive: true}
        end
      when NamedTuple(join: Symbol, stmt: String, values: Array(Grant::Columns::Type))
        values = condition[:values]
        if (match = PAIR_STATEMENT.match(condition[:stmt])) && match[1] == key_name && match[2] == key_name && values.size == 2
          {minimum: values[0], maximum: values[1], upper_exclusive: match[3] == "<"}
        elsif (match = BETWEEN_STATEMENT.match(condition[:stmt])) && match[1] == key_name && values.size == 2
          {minimum: values[0], maximum: values[1], upper_exclusive: false}
        end
      end
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
      Grant::ShardManager.route_to(@shard) do
        # Always use the non-routing method to avoid infinite recursion
        @query.as(Grant::Sharding::ShardedQueryBuilder(Model)).select_without_routing
      end
    end

    def count : Grant::Query::Builder::CountResult
      Grant::ShardManager.route_to(@shard) do
        # Always use the non-routing method to avoid infinite recursion
        @query.as(Grant::Sharding::ShardedQueryBuilder(Model)).count_without_routing
      end
    end

    def exists? : Bool
      Grant::ShardManager.route_to(@shard) do
        # Always use the non-routing method to avoid infinite recursion
        @query.as(Grant::Sharding::ShardedQueryBuilder(Model)).exists_without_routing
      end
    end

    def pluck(column : String | Symbol) : Array(Grant::Columns::Type)
      Grant::ShardManager.route_to(@shard) do
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
