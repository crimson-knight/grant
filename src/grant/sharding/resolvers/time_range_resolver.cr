module Grant::Sharding
  # Range sharding over time.
  #
  #     shards_by :created_at, strategy: :time_range, ranges: [
  #       {from: Time.utc(2024, 1, 1), to: Time.utc(2024, 7, 1), shard: :shard_2024_h1},
  #       {from: Time.utc(2024, 7, 1), to: Time.utc(2025, 1, 1), shard: :shard_2024_h2},
  #     ]
  #
  # Each range is half-open: `from` is included and `to` is excluded, the same
  # convention as PostgreSQL range partitions (`FROM ... TO ...`). Adjacent
  # ranges therefore share a boundary, and no instant falls between them.
  # `Time` keys are compared as instants, so offsets are honored.
  #
  # `String` keys in the composite-ID layout produced by
  # `CompositeId#generate_composite_id` without a prefix
  # (`YYYY_MM_DD_<13-digit unix ms>_<hex>`, UTC) route by the millisecond they
  # carry. Other strings, integers and `nil` do not resolve: the query router
  # falls back to scatter-gather for them instead of guessing a shard.
  class TimeRangeResolver < RangeResolver
    # One configured interval, `from` inclusive and `to` exclusive.
    struct TimeRange
      getter from : Time
      getter to : Time
      getter shard : Symbol

      def initialize(@from : Time, @to : Time, @shard : Symbol)
      end

      # Whether *time* is inside `[from, to)`.
      def includes?(time : Time) : Bool
        time >= @from && time < @to
      end

      # Whether this range holds any instant of the inclusive interval
      # `[minimum, maximum]`.
      def intersects?(minimum : Time, maximum : Time) : Bool
        @from <= maximum && @to > minimum
      end

      # Whether this range and *other* share any instant.
      def overlaps?(other : TimeRange) : Bool
        @from < other.to && other.from < @to
      end
    end

    COMPOSITE_ID_LAYOUT = /\A\d{4}_\d{2}_\d{2}_\d{13}(_|\z)/

    @time_ranges : Array(TimeRange)

    def initialize(@key_columns : Array(Symbol), time_ranges : Array(NamedTuple(from: Time, to: Time, shard: Symbol)))
      @time_ranges = time_ranges.map do |range|
        unless range[:from] < range[:to]
          raise ArgumentError.new("Time range for #{range[:shard]} must start before it ends: #{range[:from]} >= #{range[:to]}")
        end
        TimeRange.new(range[:from], range[:to], range[:shard])
      end
      validate_time_ranges!

      # Millisecond-precise string bounds for composite-ID keys. They are
      # derived from the validated Time ranges, so they cannot overlap.
      @ranges = @time_ranges.map do |range|
        RangeDefinition.new(composite_id_lower_bound(range.from), composite_id_upper_bound(range.to), range.shard)
      end
    end

    def all_shards : Array(Symbol)
      @time_ranges.map(&.shard).uniq
    end

    def resolve_for_values(values : Array) : Symbol
      value = values.first?
      raise ShardKeyMissingError.new("Missing shard key: #{@key_columns.first?}") if value.nil?

      if value.is_a?(Time)
        range = @time_ranges.find(&.includes?(value))
        return range.shard if range
        raise ShardNotFoundError.new("Value #{value} not in any defined range")
      end

      if value.is_a?(String) && COMPOSITE_ID_LAYOUT.matches?(value)
        range = @ranges.find(&.includes?(value))
        return range.shard if range
        raise ShardNotFoundError.new("Value #{value} not in any defined range")
      end

      raise ShardNotFoundError.new("Time range sharding needs a Time or composite-ID String key, got #{value.class}: #{value}")
    end

    # Shards whose ranges intersect the inclusive interval `[minimum, maximum]`.
    def shards_for_range(minimum : Time, maximum : Time) : Array(Symbol)
      @time_ranges.select(&.intersects?(minimum, maximum)).map(&.shard).uniq
    end

    # Prunes composite-ID String bounds only. Any other bound (an Int64, or a
    # date string such as "2024-01-01") cannot be compared with the ranges, so
    # this returns nil and the caller scatter-gathers to every shard rather
    # than returning an empty or partial result.
    def shards_for_range(minimum : String | Int64, maximum : String | Int64) : Array(Symbol)?
      return nil unless minimum.is_a?(String) && maximum.is_a?(String)
      return nil unless COMPOSITE_ID_LAYOUT.matches?(minimum) && COMPOSITE_ID_LAYOUT.matches?(maximum)
      super
    end

    # Shards that can hold rows from `now - span` through `now`.
    def shards_for_last(span : Time::Span, now : Time = Time.utc) : Array(Symbol)
      shards_for_range(now - span, now)
    end

    private def validate_time_ranges!
      @time_ranges.each_with_index do |left, index|
        @time_ranges[(index + 1)..].each do |right|
          if left.overlaps?(right)
            raise ArgumentError.new("Overlapping ranges: #{left.from}...#{left.to} and #{right.from}...#{right.to}")
          end
        end
      end
    end

    # Smallest composite ID created at or after *time*.
    private def composite_id_lower_bound(time : Time) : String
      milliseconds = time.to_unix_ms
      milliseconds += 1 if Time.unix_ms(milliseconds) < time
      composite_id_prefix(milliseconds)
    end

    # Largest composite ID created before *time*: every ID whose millisecond
    # is earlier than *time* sorts at or below this bound.
    private def composite_id_upper_bound(time : Time) : String
      milliseconds = time.to_unix_ms
      milliseconds -= 1 if Time.unix_ms(milliseconds) == time
      "#{composite_id_prefix(milliseconds)}_~"
    end

    private def composite_id_prefix(milliseconds : Int64) : String
      "#{Time.unix_ms(milliseconds).to_s("%Y_%m_%d")}_#{milliseconds.to_s.rjust(13, '0')}"
    end
  end
end
