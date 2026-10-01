module Grant::Sharding
  # Resolver for range-based sharding
  class RangeResolver < ShardResolver
    struct RangeDefinition
      getter min : String | Int64
      getter max : String | Int64
      getter shard : Symbol

      def initialize(@min, @max, @shard)
      end

      def includes?(value : String | Int64) : Bool
        case value
        when String
          value >= @min.to_s && value <= @max.to_s
        when Int64
          min_val : Int64 = @min.is_a?(Int64) ? @min.as(Int64) : (@min.as(String).to_i64? || Int64::MIN)
          max_val : Int64 = @max.is_a?(Int64) ? @max.as(Int64) : (@max.as(String).to_i64? || Int64::MAX)
          value >= min_val && value <= max_val
        else
          false
        end
      end

      # Whether this range holds a key of the interval whose open ends are
      # `nil`. Both ends and the range share one type; the caller checks.
      def intersects?(minimum : String | Int64 | Nil, maximum : String | Int64 | Nil) : Bool
        if minimum.is_a?(Int64) || maximum.is_a?(Int64)
          low = @min.as(Int64)
          high = @max.as(Int64)
          (maximum.nil? || low <= maximum.as(Int64)) && (minimum.nil? || high >= minimum.as(Int64))
        else
          low = @min.as(String)
          high = @max.as(String)
          (maximum.nil? || low <= maximum.as(String)) && (minimum.nil? || high >= minimum.as(String))
        end
      end

      def overlaps?(minimum : String | Int64, maximum : String | Int64) : Bool
        case {min, max, minimum, maximum}
        when {String, String, String, String}
          min.as(String) <= maximum && max.as(String) >= minimum
        when {Int64, Int64, Int64, Int64}
          min.as(Int64) <= maximum && max.as(Int64) >= minimum
        else
          false
        end
      end
    end

    @ranges : Array(RangeDefinition)

    def initialize(@key_columns : Array(Symbol), ranges : Array(NamedTuple(min: String | Int64, max: String | Int64, shard: Symbol)))
      @ranges = ranges.map { |r| RangeDefinition.new(r[:min], r[:max], r[:shard]) }
      validate_ranges!
    end

    def resolve(model : Grant::Base) : Symbol
      values = @key_columns.map { |col| model.read_attribute(col.to_s) }
      resolve_for_values(values)
    end

    def resolve_for_keys(**keys) : Symbol
      values = @key_columns.map { |col| keys[col]? || raise "Missing shard key: #{col}" }
      resolve_for_values(values)
    end

    def all_shards : Array(Symbol)
      @ranges.map(&.shard).uniq
    end

    # Return only shards whose configured ranges intersect an inclusive query
    # interval. A nil result means the bounds could not be compared safely.
    def shards_for_range(minimum : String | Int64, maximum : String | Int64) : Array(Symbol)?
      @ranges.select(&.overlaps?(minimum, maximum)).map(&.shard).uniq
    end

    # The shards that can hold a key between *minimum* and *maximum*, where
    # either bound may be `nil` for an open end (a query with only `>=` or
    # only `<`). *upper_exclusive* says the upper bound is a `<`. A result of
    # `nil` means the bounds cannot be compared with the ranges, so the caller
    # keeps scatter-gathering. The router calls it once per query.
    def shards_for_bounds(minimum : Grant::Columns::Type, maximum : Grant::Columns::Type, upper_exclusive : Bool = false) : Array(Symbol)?
      low = minimum.is_a?(String) || minimum.is_a?(Int64) ? minimum : nil
      high = maximum.is_a?(String) || maximum.is_a?(Int64) ? maximum : nil
      # A bound of another type (a Time, say) cannot be compared here.
      return nil if low.nil? && high.nil?
      return nil if (!minimum.nil? && low.nil?) || (!maximum.nil? && high.nil?)
      return nil if low && high && low.class != high.class

      numeric = low.is_a?(Int64) || high.is_a?(Int64)
      shards = [] of Symbol
      @ranges.each do |range|
        return nil unless numeric ? (range.min.is_a?(Int64) && range.max.is_a?(Int64)) : (range.min.is_a?(String) && range.max.is_a?(String))
        shards << range.shard if range.intersects?(low, high)
      end
      shards.uniq
    end

    def resolve_for_values(values : Array) : Symbol
      # For range sharding, typically use first key column only
      value = values.first

      unless value.is_a?(String) || value.is_a?(Int64)
        raise "Range sharding requires String or Int64 shard key, got #{value.class}"
      end

      range = @ranges.find { |r| r.includes?(value) }
      if range
        range.shard
      else
        raise "Value #{value} not in any defined range"
      end
    end

    private def validate_ranges!
      @ranges.each_with_index do |left, left_index|
        @ranges[(left_index + 1)..].each do |right|
          overlapping = case {left.min, left.max, right.min, right.max}
                        when {Int64, Int64, Int64, Int64}
                          left.min.as(Int64) <= right.max.as(Int64) && right.min.as(Int64) <= left.max.as(Int64)
                        when {String, String, String, String}
                          left.min.as(String) <= right.max.as(String) && right.min.as(String) <= left.max.as(String)
                        else
                          raise "Range bounds must use the same type"
                        end

          if overlapping
            raise "Overlapping ranges: #{left.min}-#{left.max} and #{right.min}-#{right.max}"
          end
        end
      end
    end
  end

  # Module for composite ID generation
  module CompositeId
    # Generate a time-based composite ID
    def generate_composite_id(prefix : String? = nil) : String
      now = Time.utc
      timestamp = now.to_unix_ms
      random = Random::Secure.hex(4)

      String.build do |str|
        str << prefix << "_" if prefix
        str << now.to_s("%Y_%m_%d")
        str << "_"
        str << timestamp.to_s.rjust(13, '0')
        str << "_"
        str << random
      end
    end

    # Generate a timestamp-based Int64 ID
    def generate_timestamp_id : Int64
      # Microseconds since epoch with random component
      base = (Time.utc.to_unix_f * 1_000_000).to_i64
      # Add random component in last 3 digits
      base * 1000 + Random.rand(1000).to_i64
    end
  end
end
