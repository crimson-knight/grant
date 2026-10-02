module Grant::Sharding
  class ShardMoveError < Grant::ErrorBase
    getter source_error : ::Exception
    getter compensation_error : ::Exception

    def initialize(message : String, @source_error : ::Exception, @compensation_error : ::Exception)
      super(message, cause: compensation_error)
    end
  end

  # Base class for all shard resolvers
  abstract class ShardResolver
    # Resolve shard for a model instance
    abstract def resolve(model : Grant::Base) : Symbol

    # Resolve shard for given key values (for queries)
    abstract def resolve_for_keys(**keys) : Symbol

    # Resolve shard from positional key values, in declared shard-key order.
    #
    # This is the routing entry point used by `QueryRouter`: the router has
    # only column-name strings (no symbols), so it collects shard-key values
    # positionally and resolves through this method. Every resolver must
    # implement it. Raise if the values cannot be resolved (the router treats
    # a raise as "fall back to scatter-gather").
    abstract def resolve_for_values(values : Array) : Symbol

    # Get all shards managed by this resolver
    abstract def all_shards : Array(Symbol)
  end

  # Configuration for sharding on a model
  class ShardConfig
    property key_columns : Array(Symbol)
    property resolver : ShardResolver

    # String forms of the declared shard-key columns, in declaration order.
    #
    # The query builder stores `where` fields as *strings* (Crystal has no
    # `String#to_sym`), so the router resolves routing by matching `where`
    # field strings against these names — no hard-coded symbol guessing. This
    # is what makes any declared shard key (e.g. `account_id`) route correctly.
    getter key_column_names : Array(String)

    def initialize(@key_columns : Array(Symbol), @resolver : ShardResolver)
      @key_column_names = @key_columns.map(&.to_s)
    end

    # Whether `column_name` (a `where`-field string) is a declared shard key.
    def shard_key?(column_name : String) : Bool
      @key_column_names.includes?(column_name)
    end
  end

  # Module to include in models for sharding support
  module Model
    macro included
      class_property sharding_config : Grant::Sharding::ShardConfig?
      
      extend Grant::Sharding::Model::ClassMethods

      # Override adapter to use sharded connection
      def self.adapter : Grant::Adapter::Base
        if config = sharding_config
          # For class-level queries, we need context to determine shard
          # This would typically come from query builder context
          # `ShardManager.with_shard` wins; otherwise the shard of a
          # `connected_to(shard:)` block that applies to this class.
          if shard = Grant::ShardManager.current_shard || current_shard
            Grant::ConnectionRegistry.get_adapter(database_name, current_role, shard)
          else
            # No shard context - this is an error for sharded models
            raise "No shard context for sharded model #{name}. Use .on_shard or ensure shard key is provided."
          end
        else
          # Non-sharded model - use default behavior
          super
        end
      end
      
      # A transaction on a sharded model runs on the active shard's connection,
      # the one `adapter` resolves, so its statements join the transaction.
      #
      # :nodoc:
      def self.transaction_adapter : Grant::Adapter::Base
        sharding_config ? adapter : super
      end

      # Bare class-level count for sharded models.
      #
      # The default Grant::Querying#count hits `adapter` directly, which raises
      # for a sharded model with no shard context. Route it through the sharded
      # query builder instead so `Model.count` scatter-gathers across all shards
      # (and still single-shards if a shard context is active).
      # Returns the count as `Int64`.
      def self.count : Int64
        if sharding_config
          result = __builder.count
          if result.is_a?(Int64)
            result
          else
            result.values.sum
          end
        else
          super
        end
      end

      # Query on specific shard
      def self.on_shard(shard : Symbol)
        Grant::Sharding::ShardedQuery({{@type}}).new(self, shard)
      end
      
      # Query on all shards
      def self.on_all_shards
        Grant::Sharding::MultiShardQuery({{@type}}).new(self)
      end
      
      # Execute a block on all shards
      def self.on_all_shards(&block)
        if config = sharding_config
          shards = Grant::ShardManager.shards_for_model(self.name)
          shards.each do |shard|
            Grant::ShardManager.with_shard(shard) do
              yield
            end
          end
        else
          yield # Not sharded, just execute the block
        end
      end
      
      # Iterate through all records across all shards in batches, one shard
      # after another, in keyset batches (see `find_each_shard`).
      def self.find_each(batch_size : Int32 = 1000, &block : {{@type}} ->)
        if sharding_config
          find_each_shard(batch_size: batch_size) { |record| yield record }
        else
          current_scope.find_each(batch_size: batch_size) { |record| yield record }
        end
      end
    end

    # DSL for configuring sharding
    macro shards_by(*columns, strategy = :hash, **options)
      {% if strategy == :hash %}
        self.sharding_config = Grant::Sharding::ShardConfig.new(
          key_columns: [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
          resolver: Grant::Sharding::HashResolver.new(
            [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
            {% if options[:shards] %}
              {{options[:shards]}}
            {% else %}
              {{options[:count] || 4}},
              {{options[:prefix] || "shard"}}.to_s
            {% end %}
          )
        )
      {% elsif strategy == :lookup %}
        {% unless options[:lookup] %}
          {% raise "Lookup sharding requires :lookup option" %}
        {% end %}
        self.sharding_config = Grant::Sharding::ShardConfig.new(
          key_columns: [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
          resolver: Grant::Sharding::LookupResolver.new(
            [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
            {{options[:lookup]}}.to_h,
            {{options[:default_shard]}}.as(Symbol?)
          )
        )
      {% elsif strategy == :range %}
        {% unless options[:ranges] %}
          {% raise "Range sharding requires :ranges option" %}
        {% end %}
        self.sharding_config = Grant::Sharding::ShardConfig.new(
          key_columns: [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
          resolver: Grant::Sharding::RangeResolver.new(
            [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
            {{options[:ranges]}}
          )
        )
      {% elsif strategy == :time_range %}
        {% unless options[:ranges] %}
          {% raise "Time range sharding requires :ranges option" %}
        {% end %}
        self.sharding_config = Grant::Sharding::ShardConfig.new(
          key_columns: [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
          resolver: Grant::Sharding::TimeRangeResolver.new(
            [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
            {{options[:ranges]}}
          )
        )
      {% elsif strategy == :geo %}
        {% unless options[:regions] %}
          {% raise "Geo sharding requires :regions option" %}
        {% end %}
        self.sharding_config = Grant::Sharding::ShardConfig.new(
          key_columns: [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
          resolver: Grant::Sharding::GeoResolver.new(
            [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
            {{options[:regions]}},
            {{options[:default_shard] || :shard_global}}
          )
        )
      {% else %}
        {% raise "Unsupported sharding strategy: #{strategy}" %}
      {% end %}
      
      # Register with ShardManager
      Grant::ShardManager.register(
        {{@type.name.stringify}},
        self.sharding_config.not_nil!
      )
      
      # Override query builder to use sharded version
      # :nodoc:
      def self.__builder
        # For sharded models, we can't call adapter directly since it requires shard context
        # Instead, we'll default to sqlite for now - the actual adapter will be determined
        # when the query is executed with proper shard context
        db_type = Grant::Query::Builder::DbType::Sqlite
        
        Grant::Sharding::ShardedQueryBuilder({{@type}}).new(db_type, :and, self.sharding_config)
      end
    end

    # Copy a persisted record to another shard, then remove the source copy.
    # Cross-database transactions are not available, so a failed source delete
    # triggers a compensating delete on the destination. If compensation also
    # fails, the raised error reports that both copies may need reconciliation.
    def move_to_shard(target_shard : Symbol, from_shard : Symbol? = nil)
      raise "Cannot move an unpersisted record" unless persisted?

      config = self.class.sharding_config || raise "Model #{self.class.name} is not configured for sharding"
      raise ArgumentError.new("Unknown target shard #{target_shard} for #{self.class.name}") unless config.resolver.all_shards.includes?(target_shard)

      source_shard = from_shard || @current_shard || config.resolver.resolve(self)
      raise ArgumentError.new("Unknown source shard #{source_shard} for #{self.class.name}") unless config.resolver.all_shards.includes?(source_shard)
      return self if source_shard == target_shard
      resolved_destination = config.resolver.resolve(self)
      unless resolved_destination == target_shard
        raise ArgumentError.new("Current shard key resolves to #{resolved_destination}; update the shard key for #{self.class.name} before moving it to #{target_shard}")
      end

      destination_record = self.class.new
      self.class.content_fields.each do |field|
        destination_record.write_attribute(field, read_attribute(field))
      end
      destination_record.write_attribute(self.class.primary_name, read_attribute(self.class.primary_name))
      destination_record.current_shard = target_shard
      self.current_shard = source_shard

      Grant::ShardManager.with_shard(target_shard) do
        destination_record.save!
      end

      begin
        Grant::ShardManager.with_shard(source_shard) do
          destroy!
        end
      rescue source_error
        begin
          Grant::ShardManager.with_shard(target_shard) do
            destination_record.destroy!
          end
        rescue compensation_error
          raise ShardMoveError.new(
            "Move of #{self.class.name} #{primary_key_value} failed on source cleanup (#{source_error.message}); destination compensation also failed (#{compensation_error.message})",
            source_error,
            compensation_error
          )
        end
        raise source_error
      end

      destination_record
    end
  end

  # Query builder for sharded queries - use ShardedScope instead
  # Keeping for backward compatibility but delegating to new implementation
  class ShardedQuery(Model)
    @scope : ShardedScope(Model)

    def initialize(@model : Model.class, @shard : Symbol)
      @scope = ShardedScope(Model).new(@model, @shard)
    end

    def where(**conditions)
      @scope.where(**conditions)
    end

    def all
      @scope.all
    end

    # Returns scalar or grouped counts from the selected shard.
    def count : Grant::Query::Builder::CountResult
      @scope.count
    end

    def find(id)
      @scope.find(id)
    end
  end

  # Query builder for multi-shard queries - use MultiShardScope instead
  # Keeping for backward compatibility but delegating to new implementation
  class MultiShardQuery(Model)
    @scope : MultiShardScope(Model)

    def initialize(@model : Model.class)
      @scope = MultiShardScope(Model).new(@model)
    end

    # Returns the summed count across all shards as `Int64`.
    def count : Int64
      result = @scope.count
      if result.is_a?(Int64)
        result
      else
        result.values.sum
      end
    end

    def where(**conditions)
      @scope.where(**conditions)
    end

    def all
      @scope.all
    end
  end
end

# Require additional resolvers after base classes are defined
require "./sharding/shard_manager"
require "./sharding/query_router"
require "./sharding/sharded_query_builder"
require "./sharding/scatter_gather"
require "./sharding/model"
require "./sharding/range_resolver"
require "./sharding/resolvers/hash_resolver"
require "./sharding/resolvers/lookup_resolver"
require "./sharding/resolvers/time_range_resolver"
require "./sharding/geo_resolver"
