module Grant::Sharding
  # Range sharding over time.
  #
  #     shards_by :created_at, strategy: :time_range, ranges: [
  #       {from: Time.utc(2024, 1, 1), to: Time.utc(2024, 6, 30, 23, 59, 59), shard: :shard_2024_h1},
  #       {from: Time.utc(2024, 7, 1), to: Time.utc(2024, 12, 31, 23, 59, 59), shard: :shard_2024_h2},
  #     ]
  #
  # Bounds are inclusive on both ends, so adjacent ranges must not share an
  # instant. `Time` keys are compared as instants (offsets are honored).
  #
  # `String` keys in the composite-ID layout (`%Y_%m_%d_...`, see `CompositeId`)
  # keep working: each range is also converted to a day-granular string range,
  # and the whole `to` day is included for string keys.
  class TimeRangeResolver < RangeResolver
    struct TimeRange
      getter from : Time
      getter to : Time
      getter shard : Symbol

      def initialize(@from : Time, @to : Time, @shard : Symbol)
      end

      def includes?(time : Time) : Bool
        time >= @from && time <= @to
      end

      def overlaps?(minimum : Time, maximum : Time) : Bool
        @from <= maximum && @to >= minimum
      end
    end

    @time_ranges : Array(TimeRange)

    def initialize(@key_columns : Array(Symbol), time_ranges : Array(NamedTuple(from: Time, to: Time, shard: Symbol)))
      time_ranges.each do |range|
        if range[:from] > range[:to]
          raise ArgumentError.new("Time range for #{range[:shard]} starts after it ends: #{range[:from]} > #{range[:to]}")
        end
      end
      @time_ranges = time_ranges.map { |range| TimeRange.new(range[:from], range[:to], range[:shard]) }
      validate_time_ranges!

      # Day-granular string ranges for composite-ID String keys.
      string_ranges = time_ranges.map do |range|
        {
          min:   range[:from].to_s("%Y_%m_%d_000000"),
          max:   range[:to].to_s("%Y_%m_%d_999999"),
          shard: range[:shard],
        }
      end
      super(@key_columns, string_ranges)
    end

    def all_shards : Array(Symbol)
      @time_ranges.map(&.shard).uniq
    end

    def resolve_for_values(values : Array) : Symbol
      value = values.first
      if value.is_a?(Time)
        range = @time_ranges.find(&.includes?(value))
        return range.shard if range
        raise ShardNotFoundError.new("Value #{value} not in any defined range")
      end
      super
    end

    # Shards whose ranges intersect the inclusive interval [minimum, maximum].
    def shards_for_range(minimum : Time, maximum : Time) : Array(Symbol)
      @time_ranges.select(&.overlaps?(minimum, maximum)).map(&.shard).uniq
    end

    # Shards that can hold rows newer than `now - span` (up to `now`).
    def shards_for_last(span : Time::Span, now : Time = Time.utc) : Array(Symbol)
      shards_for_range(now - span, now)
    end

    private def validate_time_ranges!
      @time_ranges.each_with_index do |left, index|
        @time_ranges[(index + 1)..].each do |right|
          if left.overlaps?(right.from, right.to)
            raise ArgumentError.new("Overlapping ranges: #{left.from}-#{left.to} and #{right.from}-#{right.to}")
          end
        end
      end
    end
  end
end
