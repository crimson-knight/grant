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

  # Helper for time-based range sharding
  class TimeRangeResolver < RangeResolver
    def initialize(@key_columns : Array(Symbol), time_ranges : Array(NamedTuple(from: Time, to: Time, shard: Symbol)))
      # Convert time ranges to string ranges for composite IDs
      string_ranges = time_ranges.map do |range|
        {
          min:   range[:from].to_s("%Y_%m_%d_000000"),
          max:   range[:to].to_s("%Y_%m_%d_999999"),
          shard: range[:shard],
        }
      end
      super(@key_columns, string_ranges)
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
