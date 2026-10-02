module Grant::Sharding
  # Raised when a shard key is required but absent.
  class ShardKeyMissingError < Grant::ErrorBase
  end

  # Raised when no shard is configured for a key value.
  class ShardNotFoundError < Grant::ErrorBase
  end

  # Lookup-based sharding resolver: an explicit table of key value => shard,
  # with an optional default for unlisted values.
  #
  #     shards_by :country, strategy: :lookup,
  #       lookup: {"US" => :shard_us, "DE" => :shard_eu},
  #       default_shard: :shard_global
  #
  # Key values are matched by their `to_s` form.
  class LookupResolver < ShardResolver
    getter lookup_table : Hash(String, Symbol)
    getter default_shard : Symbol?

    def initialize(@key_column : Symbol, @lookup_table : Hash(String, Symbol), @default_shard : Symbol? = nil)
    end

    # `shards_by` passes the key column list.
    def initialize(key_columns : Array(Symbol), lookup_table : Hash(String, Symbol), default_shard : Symbol? = nil)
      initialize(key_columns.first, lookup_table, default_shard)
    end

    def resolve(model : Grant::Base) : Symbol
      resolve_for_values([model.read_attribute(@key_column.to_s)])
    end

    def resolve_for_keys(**keys) : Symbol
      value = keys[@key_column]?
      raise ShardKeyMissingError.new("Missing shard key: #{@key_column}") if value.nil?
      shard_for(value.to_s)
    end

    def resolve_for_values(values : Array) : Symbol
      value = values.first?
      raise ShardKeyMissingError.new("Missing shard key: #{@key_column}") if value.nil?
      shard_for(value.to_s)
    end

    # Every distinct shard, each listed once (the default shard is appended
    # only when the table does not already route to it).
    def all_shards : Array(Symbol)
      shards = @lookup_table.values.uniq!
      if default = @default_shard
        shards << default unless shards.includes?(default)
      end
      shards
    end

    private def shard_for(value : String) : Symbol
      @lookup_table[value]? || @default_shard || raise ShardNotFoundError.new("No shard found for value: #{value}")
    end
  end
end
