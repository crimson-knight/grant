module Grant::Sharding
  # Raised when a hash resolver is configured with a shard count or shard list
  # it cannot serve.
  class UnsupportedShardCountError < Grant::ErrorBase
  end

  # Built-in hash sharding resolver.
  #
  # Keys are hashed with 64-bit FNV-1a, which is stable across processes,
  # restarts, machines and Crystal versions (unlike `Object#hash`, which is
  # seeded randomly per process). The shard is `hash % shard_count`.
  #
  # Key bytes fed to the hash:
  # * integers hash as their 8-byte little-endian `Int64` value (no string
  #   allocation for the common single-column integer key);
  # * strings hash as their UTF-8 bytes, except that a canonical decimal
  #   integer string ("42", not "042") hashes like the integer 42, so a key
  #   read from a record and the same key bound from a query string route
  #   alike;
  # * anything else (UUID, Time, Bool, ...) hashes as its `to_s` bytes;
  # * composite keys hash each part in declared order with a 0xFF separator.
  #
  # Migration warning: this replaces the former `String#hash` routing. Rows
  # already written to shards under that routing were placed by a process-seeded
  # value that cannot be reproduced, so anyone with existing sharded data must
  # re-home rows (read each row, resolve its shard with this resolver, move it)
  # before relying on hash routing. Changing the algorithm later needs the same
  # data migration.
  class HashResolver < ShardResolver
    # Largest shard count served by the generated name table.
    MAX_SHARD_COUNT = 256

    FNV_OFFSET_BASIS = 0xcbf29ce484222325_u64
    FNV_PRIME        =      0x100000001b3_u64
    KEY_SEPARATOR    =                0xFF_u8

    # Symbols cannot be built at run time, so the default names
    # (:shard_0 ... :shard_255) are generated once at compile time.
    SHARD_NAMES = {% begin %}
      [
        {% for i in 0...256 %}
          {{ ("shard_" + i.stringify).id.symbolize }},
        {% end %}
      ] of Symbol
    {% end %}

    getter shard_count : Int32
    getter shard_prefix : String

    @shards : Array(Symbol)

    # Hash across `shard_count` shards named :shard_0 ... :shard_N-1.
    # Any count from 1 through `MAX_SHARD_COUNT` is accepted. `shard_prefix`
    # is kept for API compatibility; symbol names always use `shard_`.
    def initialize(@key_columns : Array(Symbol), @shard_count : Int32, @shard_prefix : String = "shard")
      unless 1 <= @shard_count <= MAX_SHARD_COUNT
        raise UnsupportedShardCountError.new("Unsupported shard count: #{@shard_count}. Supported counts are 1 through #{MAX_SHARD_COUNT}, or pass explicit shards")
      end
      @shards = SHARD_NAMES[0, @shard_count]
    end

    # Hash across explicitly named shards; the count is `shards.size`.
    def initialize(@key_columns : Array(Symbol), shards : Array(Symbol))
      raise UnsupportedShardCountError.new("At least one shard is required") if shards.empty?
      unique = shards.uniq
      raise UnsupportedShardCountError.new("Duplicate shard names: #{shards.inspect}") unless unique.size == shards.size
      @shards = unique
      @shard_count = unique.size
      @shard_prefix = "shard"
    end

    def resolve(model : Grant::Base) : Symbol
      values = @key_columns.map { |col| model.read_attribute(col.to_s) }
      resolve_for_values(values)
    end

    def resolve_for_keys(**keys) : Symbol
      values = @key_columns.map do |col|
        raise ShardKeyMissingError.new("Missing shard key: #{col}") unless keys.has_key?(col)
        keys[col]
      end
      resolve_for_values(values)
    end

    def all_shards : Array(Symbol)
      @shards
    end

    def resolve_for_values(values : Array) : Symbol
      hash = FNV_OFFSET_BASIS
      values.each_with_index do |value, index|
        hash = (hash ^ KEY_SEPARATOR.to_u64) &* FNV_PRIME if index > 0
        hash = mix(hash, value)
      end
      @shards[(hash % @shard_count.to_u64).to_i]
    end

    # Stable 64-bit hash of a key (exposed for tooling and migrations).
    def self.stable_hash(value) : UInt64
      new_hash = FNV_OFFSET_BASIS
      mix_value(new_hash, value)
    end

    private def mix(hash : UInt64, value) : UInt64
      self.class.mix_value(hash, value)
    end

    # :nodoc:
    def self.mix_value(hash : UInt64, value : Int) : UInt64
      mix_int(hash, value.to_i64!)
    end

    # :nodoc:
    def self.mix_value(hash : UInt64, value : String) : UInt64
      if (number = value.to_i64?) && number.to_s == value
        mix_int(hash, number)
      else
        mix_bytes(hash, value.to_slice)
      end
    end

    # :nodoc:
    def self.mix_value(hash : UInt64, value) : UInt64
      mix_bytes(hash, value.to_s.to_slice)
    end

    # :nodoc:
    def self.mix_int(hash : UInt64, number : Int64) : UInt64
      bits = number.to_u64!
      8.times do
        hash = (hash ^ (bits & 0xFF_u64)) &* FNV_PRIME
        bits >>= 8
      end
      hash
    end

    # :nodoc:
    def self.mix_bytes(hash : UInt64, bytes : Bytes) : UInt64
      bytes.each { |byte| hash = (hash ^ byte.to_u64) &* FNV_PRIME }
      hash
    end
  end
end
