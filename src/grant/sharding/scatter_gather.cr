require "big"
require "./query_router"

module Grant::Sharding
  # Raised when an aggregate cannot be merged from per-shard results: a
  # DISTINCT aggregate, or one over a relation with LIMIT or OFFSET, across
  # more than one shard. The answer would be wrong, so Grant refuses it.
  class ScatterAggregateError < Grant::ErrorBase
  end

  # Orders two non-nil column values: numbers by value, times and strings
  # naturally, anything else by its text.
  def self.compare_column_values(left : Grant::Columns::Type, right : Grant::Columns::Type) : Int32
    ordering = if left.is_a?(Number) && right.is_a?(Number)
                 left <=> right
               elsif left.is_a?(String) && right.is_a?(String)
                 left <=> right
               elsif left.is_a?(Time) && right.is_a?(Time)
                 left <=> right
               else
                 left.to_s <=> right.to_s
               end
    ordering || 0
  end

  # Runs a query on several shards and merges what comes back.
  #
  # * Rows: each shard gets `LIMIT (limit + offset)` and no OFFSET. The rows
  #   are merge-sorted by the relation's ORDER BY, then the offset is dropped
  #   and the limit taken, so a global page is right. Deep pages cost
  #   `limit + offset` rows per shard: prefer keyset pagination
  #   (`find_each_shard`, or `where("id > ?", last_id).order(id: :asc).limit(n)`).
  # * Aggregates: sum adds the per-shard sums, min and max take the extremum of
  #   the per-shard extrema, count adds counts, and average divides the total
  #   of the per-shard sums by the total of the per-shard counts. It never
  #   averages the averages.
  #
  # With one shard the work runs inline; with several, one fiber per shard.
  class ScatterGatherExecution(Model) < QueryExecution(Model)
    alias SumValue = Grant::Query::Builder::SumValue
    alias SumResult = Grant::Query::Builder::SumResult
    alias AverageResult = Grant::Query::Builder::AverageResult
    alias ExtremumResult = Grant::Query::Builder::ExtremumResult
    alias CountResult = Grant::Query::Builder::CountResult

    @query : Grant::Query::Builder(Model)
    @shards : Array(Symbol)

    def initialize(@model : Model.class, query : Grant::Query::Builder(Model), shards : Array(Symbol))
      @query = query
      @shards = shards.uniq
    end

    def execute : Array(Model)
      limit = @query.limit
      offset = @query.offset || 0_i64
      fetch = shard_fetch_query(limit, offset)

      results = gather { |_| local(fetch).select_without_routing }
      merge_results(results, limit, offset)
    end

    # COUNT(*) over the targeted shards. A LIMIT or OFFSET applies to the
    # merged rows: each shard counts at most `limit + offset` rows with no
    # OFFSET, and the offset and limit are applied to the total.
    def count : CountResult
      if paged_across_shards?
        guard_page_mergeable!("count")
        return page_count(@query.limit, @query.offset || 0_i64)
      end

      results = gather { |_| local(@query).count_without_routing }
      merge_count_results(results)
    end

    # COUNT(column), or COUNT(DISTINCT column) when *distinct*.
    def count(column : Symbol | String, distinct : Bool) : CountResult
      guard_mergeable!("count", distinct)
      results = gather { |_| local(@query).count(column, distinct) }
      merge_count_results(results)
    end

    def exists? : Bool
      # An OFFSET skips rows of the merged result, so no single shard can
      # answer alone: count the first row past the offset instead.
      offset = @query.offset || 0_i64
      if @shards.size > 1 && offset > 0
        guard_page_mergeable!("exists?")
        limit = @query.limit
        return page_count(limit ? Math.min(limit, 1_i64) : 1_i64, offset) > 0
      end

      # A shard that answers yes ends the search.
      @shards.each do |shard|
        found = Grant::ShardManager.route_to(shard) do
          local(@query).exists_without_routing
        end
        return true if found
      end
      false
    end

    # The values of *column* over the targeted shards. With an ORDER BY,
    # LIMIT or OFFSET, each shard returns *column* plus the ORDER BY columns
    # for `limit + offset` rows; the rows are merge-sorted, the page is cut
    # once, and NULL values are dropped afterward, as a single database does.
    def pluck(column : String | Symbol) : Array(Grant::Columns::Type)
      if merges_plucked_rows?
        values = [] of Grant::Columns::Type
        pluck_rows([column.to_s]).each do |row|
          value = row[0]
          values << value unless value.nil?
        end
        return values
      end

      results = gather { |_| local(@query).pluck_without_routing(column) }
      values = [] of Grant::Columns::Type
      results.each { |shard_values| values.concat(shard_values) }
      @query.distinct? ? values.uniq : values
    end

    # Rows of *field_names* over the targeted shards, ordered and paged like
    # `pluck(column)`.
    def pluck_rows(field_names : Array(String)) : Array(Array(Grant::Columns::Type))
      unless merges_plucked_rows?
        rows = [] of Array(Grant::Columns::Type)
        gather { |_| local(@query).pluck_rows_without_routing(field_names) }.each { |shard_rows| rows.concat(shard_rows) }
        return @query.distinct? ? rows.uniq : rows
      end

      guard_page_mergeable!("pluck")
      paged_pluck_rows(field_names)
    end

    def sum(column : Symbol | String) : SumResult
      guard_mergeable!("sum", @query.distinct?)
      results = gather { |_| local(@query).sum(column) }
      merge_sums(results)
    end

    # The sum as exactly *type*; see `Builder#sum(column, as:)`.
    def sum(column : Symbol | String, as type : T.class) : T forall T
      guard_mergeable!("sum", @query.distinct?)
      results = gather { |_| local(@query).sum(column, as: type) }
      results.reduce { |total, value| total + value }
    end

    # The average from the per-shard sums and counts, `nil` when no rows match.
    def average(column : Symbol | String) : AverageResult
      guard_mergeable!("average", @query.distinct?)
      sums = gather { |_| local(@query).sum(column) }
      counts = gather { |_| local(@query).count(column) }
      merge_averages(merge_sums(sums), merge_count_results(counts))
    end

    # MIN or MAX of *column*: the best value any shard reports.
    def extremum(function : String, column : Symbol | String) : ExtremumResult
      results = gather do |_|
        function == "MIN" ? local(@query).min(column) : local(@query).max(column)
      end
      merge_extrema(results, function == "MIN")
    end

    # A copy of the relation that runs on the current shard without routing.
    private def local(query : Grant::Query::Builder(Model)) : Grant::Sharding::ShardedQueryBuilder(Model)
      query.as(Grant::Sharding::ShardedQueryBuilder(Model)).local_execution
    end

    # The relation each shard runs: `limit + offset` rows and no OFFSET, so
    # the offset can be applied once over the merged rows.
    private def shard_fetch_query(limit : Int64?, offset : Int64) : Grant::Query::Builder(Model)
      return @query if offset == 0

      fetch = @query.dup
      fetch.offset!(nil)
      fetch.limit!(limit + offset) if limit
      fetch
    end

    private def guard_mergeable!(operation : String, distinct : Bool) : Nil
      return if @shards.size < 2

      if distinct
        raise ScatterAggregateError.new("#{Model.name}: DISTINCT #{operation} across #{@shards.size} shards cannot be merged; the same value can live on several shards")
      end
      if @query.limit || @query.offset
        raise ScatterAggregateError.new("#{Model.name}: #{operation} over a relation with LIMIT or OFFSET across #{@shards.size} shards cannot be merged")
      end
    end

    # Whether the relation pages its rows (LIMIT or OFFSET) across more than
    # one shard, so the page has to be cut over the merged rows.
    private def paged_across_shards? : Bool
      @shards.size > 1 && !!(@query.limit || @query.offset)
    end

    # A page of grouped or DISTINCT rows cannot be rebuilt from per-shard
    # pages: a group or a value can span shards.
    private def guard_page_mergeable!(operation : String) : Nil
      return if @query.group_fields.empty? && !@query.distinct?

      raise ScatterAggregateError.new("#{Model.name}: #{operation} over a grouped or DISTINCT relation with LIMIT, OFFSET or ORDER BY across #{@shards.size} shards cannot be merged")
    end

    # The number of rows in the global page `OFFSET offset LIMIT limit`.
    private def page_count(limit : Int64?, offset : Int64) : Int64
      fetch = shard_fetch_query(limit, offset)
      total = 0_i64
      gather { |_| local(fetch).count_without_routing }.each do |result|
        total += result if result.is_a?(Int64)
      end

      remaining = Math.max(total - offset, 0_i64)
      limit ? Math.min(remaining, limit) : remaining
    end

    # Whether plucked rows need a merge-sort and a global page cut.
    private def merges_plucked_rows? : Bool
      @shards.size > 1 && (paged_across_shards? || !@query.order_fields.empty?)
    end

    # Each shard plucks *plucked* plus the ORDER BY columns for
    # `limit + offset` rows; the rows are merge-sorted, the page is cut once,
    # and the ORDER BY columns are dropped again.
    private def paged_pluck_rows(plucked : Array(String)) : Array(Array(Grant::Columns::Type))
      order_fields = @query.order_fields
      width = plucked.size
      field_names = plucked + order_fields.map(&.[:field])
      limit = @query.limit
      offset = @query.offset || 0_i64
      fetch = shard_fetch_query(limit, offset)

      rows = [] of Array(Grant::Columns::Type)
      gather { |_| local(fetch).pluck_rows_without_routing(field_names) }.each { |shard_rows| rows.concat(shard_rows) }

      unless order_fields.empty?
        indexed = rows.map_with_index { |row, index| {row, index} }
        indexed.sort! do |a, b|
          comparison = compare_rows(a[0], b[0], order_fields, width)
          comparison == 0 ? a[1] <=> b[1] : comparison
        end
        rows = indexed.map(&.[0])
      end

      start = offset.to_i
      return [] of Array(Grant::Columns::Type) if start >= rows.size

      last = limit ? Math.min(start + limit.to_i, rows.size) : rows.size
      rows[start...last].map { |row| row[0, width] }
    end

    # Orders two plucked rows by their ORDER BY values, which follow the
    # *width* plucked columns.
    private def compare_rows(a : Array(Grant::Columns::Type), b : Array(Grant::Columns::Type), order_fields : Array(NamedTuple(field: String, direction: Grant::Query::Builder::Sort)), width : Int32) : Int32
      order_fields.each_with_index do |order, index|
        comparison = compare_nullable(a[index + width], b[index + width], order[:direction])
        return comparison if comparison != 0
      end
      0
    end

    # NULL sorts first ascending and last descending (the SQLite and MySQL
    # convention), matching the row merge.
    private def compare_nullable(val_a : Grant::Columns::Type, val_b : Grant::Columns::Type, direction : Grant::Query::Builder::Sort) : Int32
      if val_a.nil? && val_b.nil?
        0
      elsif val_a.nil?
        direction.sorts_descending? ? 1 : -1
      elsif val_b.nil?
        direction.sorts_descending? ? -1 : 1
      else
        comparison = Grant::Sharding.compare_column_values(val_a, val_b)
        direction.sorts_descending? ? -comparison : comparison
      end
    end

    # Runs *block* on every shard and returns the results in shard order. The
    # calling fiber's role and write prevention carry into the shard fibers.
    private def gather(&block : Symbol -> T) : Array(T) forall T
      if @shards.size == 1
        shard = @shards.first
        return [Grant::ShardManager.route_to(shard) { block.call(shard) }]
      end

      role = @model.current_role
      prevent_writes = @model.preventing_writes?
      model = @model
      results = Grant::Async::ShardedExecutor.execute_and_wait(@shards) do |shard|
        Grant::Async::AsyncResult.new do
          Grant::ShardManager.route_to(shard) do
            if role != :primary || prevent_writes
              model.connected_to(role: role, prevent_writes: prevent_writes) { block.call(shard) }
            else
              block.call(shard)
            end
          end
        end
      end
      results.values
    end

    private def merge_results(shard_results : Array(Array(Model)), limit : Int64?, offset : Int64) : Array(Model)
      merged = shard_results.flatten

      # Apply any ORDER BY from the original query. The sort is stable, so
      # rows that tie keep their shard order.
      order_fields = @query.order_fields
      unless order_fields.empty?
        indexed = merged.map_with_index { |record, index| {record, index} }
        indexed.sort! do |a, b|
          comparison = compare_by_order_fields(a[0], b[0], order_fields)
          comparison == 0 ? a[1] <=> b[1] : comparison
        end
        merged = indexed.map(&.[0])
      end

      start = offset.to_i
      return [] of Model if start >= merged.size

      last = limit ? Math.min(start + limit.to_i, merged.size) : merged.size
      merged[start...last]
    end

    private def compare_by_order_fields(a : Model, b : Model, order_fields : Array(NamedTuple(field: String, direction: Grant::Query::Builder::Sort))) : Int32
      order_fields.each do |order|
        field = order[:field]
        direction = order[:direction]

        comparison = compare_nullable(a.read_attribute(field), b.read_attribute(field), direction)
        return comparison if comparison != 0
      end

      0 # Equal
    end

    private def merge_count_results(results : Array(CountResult)) : CountResult
      case @query.group_fields.size
      when 0
        total = 0_i64
        results.each { |result| total += result if result.is_a?(Int64) }
        total
      when 1
        counts = {} of Grant::Columns::Type => Int64
        results.each do |result|
          next unless result.is_a?(Hash(Grant::Columns::Type, Int64))
          result.each { |key, count| counts[key] = counts.fetch(key, 0_i64) + count }
        end
        counts
      else
        counts = {} of Array(Grant::Columns::Type) => Int64
        results.each do |result|
          next unless result.is_a?(Hash(Array(Grant::Columns::Type), Int64))
          result.each { |key, count| counts[key] = counts.fetch(key, 0_i64) + count }
        end
        counts
      end
    end

    private def merge_sums(results : Array(SumResult)) : SumResult
      case @query.group_fields.size
      when 0
        total : SumValue = 0_i64
        results.each { |result| total = add_sums(total, result) if result.is_a?(SumValue) }
        total
      when 1
        sums = {} of Grant::Columns::Type => SumValue
        results.each do |result|
          next unless result.is_a?(Hash(Grant::Columns::Type, SumValue))
          result.each { |key, value| sums[key] = (existing = sums[key]?) ? add_sums(existing, value) : value }
        end
        sums
      else
        sums = {} of Array(Grant::Columns::Type) => SumValue
        results.each do |result|
          next unless result.is_a?(Hash(Array(Grant::Columns::Type), SumValue))
          result.each { |key, value| sums[key] = (existing = sums[key]?) ? add_sums(existing, value) : value }
        end
        sums
      end
    end

    private def add_sums(a : SumValue, b : SumValue) : SumValue
      if a.is_a?(Int64) && b.is_a?(Int64)
        a + b
      elsif a.is_a?(Float64) || b.is_a?(Float64)
        a.to_f64 + b.to_f64
      else
        BigDecimal.new(a.to_s) + BigDecimal.new(b.to_s)
      end
    end

    private def merge_averages(sums : SumResult, counts : CountResult) : AverageResult
      if sums.is_a?(SumValue) && counts.is_a?(Int64)
        return average_of(sums, counts)
      end

      if sums.is_a?(Hash(Grant::Columns::Type, SumValue)) && counts.is_a?(Hash(Grant::Columns::Type, Int64))
        averages = {} of Grant::Columns::Type => Float64?
        sums.each { |key, total| averages[key] = average_of(total, counts.fetch(key, 0_i64)) }
        return averages
      end

      averages = {} of Array(Grant::Columns::Type) => Float64?
      if sums.is_a?(Hash(Array(Grant::Columns::Type), SumValue)) && counts.is_a?(Hash(Array(Grant::Columns::Type), Int64))
        sums.each { |key, total| averages[key] = average_of(total, counts.fetch(key, 0_i64)) }
      end
      averages
    end

    private def average_of(total : SumValue, count : Int64) : Float64?
      return if count == 0
      total.to_f64 / count
    end

    private def merge_extrema(results : Array(ExtremumResult), minimum : Bool) : ExtremumResult
      case @query.group_fields.size
      when 0
        best : Grant::Columns::Type = nil
        results.each do |result|
          next if result.is_a?(Hash)
          best = better_extremum(best, result, minimum)
        end
        best
      when 1
        extrema = {} of Grant::Columns::Type => Grant::Columns::Type
        results.each do |result|
          next unless result.is_a?(Hash(Grant::Columns::Type, Grant::Columns::Type))
          result.each { |key, value| extrema[key] = better_extremum(extrema[key]?, value, minimum) }
        end
        extrema
      else
        extrema = {} of Array(Grant::Columns::Type) => Grant::Columns::Type
        results.each do |result|
          next unless result.is_a?(Hash(Array(Grant::Columns::Type), Grant::Columns::Type))
          result.each { |key, value| extrema[key] = better_extremum(extrema[key]?, value, minimum) }
        end
        extrema
      end
    end

    private def better_extremum(current : Grant::Columns::Type, candidate : Grant::Columns::Type, minimum : Bool) : Grant::Columns::Type
      return current if candidate.nil?
      return candidate if current.nil?

      ordering = Grant::Sharding.compare_column_values(candidate, current)
      (minimum ? ordering < 0 : ordering > 0) ? candidate : current
    end
  end
end
