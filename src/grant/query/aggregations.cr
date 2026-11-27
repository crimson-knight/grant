require "../strict_annotations"
require "./builder"
require "./executors/aggregate"

module Grant
  # The aggregate `Grant::Query::Builder#calculate` computes.
  enum Calculation
    Count
    Sum
    Average
    Minimum
    Maximum

    # Maps the ActiveRecord operation names (`:count`, `:sum`, `:average` or
    # `:avg`, `:minimum` or `:min`, `:maximum` or `:max`) to a `Calculation`.
    # Raises `ArgumentError` for any other symbol.
    @[TypeOnce]
    def self.from_symbol(name : Symbol) : Calculation
      case name
      when :count         then Count
      when :sum           then Sum
      when :average, :avg then Average
      when :minimum, :min then Minimum
      when :maximum, :max then Maximum
      else
        raise ArgumentError.new("Unknown calculation #{name.inspect}; use :count, :sum, :average, :minimum or :maximum")
      end
    end
  end
end

class Grant::Query::Builder(Model)
  # An exact sum: `Int64` for integer columns, `Float64` for float columns,
  # `Int64` or `BigDecimal` when the column type is not known at compile time
  # (an expression, a joined column). Without `grant/big_decimal` there is no
  # `BigDecimal`: such a sum is an `Int64` when it is a whole number in range
  # and a `Float64` otherwise.
  {% if Grant::BIG_DECIMAL_SUPPORT %}
    alias SumValue = Int64 | Float64 | BigDecimal | Grant::Decimal128
  {% else %}
    alias SumValue = Int64 | Float64 | Grant::Decimal128
  {% end %}

  alias SumResult = SumValue | Hash(Grant::Columns::Type, SumValue) | Hash(Array(Grant::Columns::Type), SumValue)
  alias AverageResult = Float64? | Hash(Grant::Columns::Type, Float64?) | Hash(Array(Grant::Columns::Type), Float64?)
  alias ExtremumResult = Grant::Columns::Type | Hash(Grant::Columns::Type, Grant::Columns::Type) | Hash(Array(Grant::Columns::Type), Grant::Columns::Type)
  alias CalculationResult = CountResult | SumResult | AverageResult | ExtremumResult

  alias AggregateRows = Array(Grant::Query::Executor::AggregateRow)

  # Counts rows whose *column* is not NULL (`COUNT(column)`), or the distinct
  # values of it with `distinct: true` (`COUNT(DISTINCT column)`, one statement,
  # no subquery over full rows). A relation made `distinct` counts distinct
  # values too. `count(:all)` and `count("*")` are `count`. A grouped relation
  # returns a `Hash` per group.
  #
  # ```
  # User.count(:deleted_at)                 # rows with a value
  # User.count(:email, distinct: true)      # distinct emails
  # Order.group(:status).count(:shipped_at) # => {"open" => 2, "done" => 5}
  # ```
  @[TypeOnce]
  def count(column : Symbol | String, distinct : Bool = false) : CountResult
    name = column.to_s
    return count if (name == "all" || name == "*") && !distinct

    name = "*" if name == "all"
    distinct ||= distinct?
    if name == "*" && distinct
      raise ArgumentError.new("count(distinct: true) needs a column")
    end
    return empty_aggregate_count if is_none?

    if should_chunk_in?
      if distinct || group_fields.any? || @limit || @offset
        raise ArgumentError.new("count(column) with a chunked IN list cannot preserve distinct, group, limit or offset")
      end
      total = 0_i64
      each_in_chunk { |chunk_query| total += count_of_rows(chunk_query.aggregate_rows("COUNT", name, :none, false)) }
      return total
    end

    rows = with_index_hint_fallback { |query| query.aggregate_rows("COUNT", name, :none, distinct) }
    return count_of_rows(rows) if group_fields.empty?

    grouped_values(rows, Int64) { |value| value.is_a?(Int) ? value.to_i64 : 0_i64 }
  end

  # The sum of *column* over the relation. An integer column gives an exact
  # `Int64` (no Float64 rounding above 2**53), a float column a `Float64`, and
  # an expression or joined column an `Int64` or `BigDecimal` (see `SumValue`
  # for apps without `grant/big_decimal`). A `Grant::Decimal128` or
  # `Grant::Money` column gives an exact `Grant::Decimal128` at the column
  # scale (a Money column sums its amounts; filter by currency first). An
  # empty relation
  # sums to zero. A grouped relation returns one `Hash` entry per group from a
  # single GROUP BY statement.
  #
  # ```
  # Order.where(paid: true).sum(:cents) # => 1_250_000_i64
  # Order.group(:status).sum(:cents)    # => {"open" => 400_i64, "done" => 850_i64}
  # ```
  @[TypeOnce]
  def sum(column : Symbol | String) : SumResult
    name = column.to_s
    if shape = exact_decimal_shape(name)
      return exact_decimal_sum(name, shape[0], shape[1])
    end
    kind = numeric_kind(name)
    zero = zero_sum(kind)
    if is_none?
      return group_fields.empty? ? zero : empty_aggregate_hash(SumValue)
    end

    if should_chunk_in?
      return chunked_sum(name, kind, zero)
    end

    rows = with_index_hint_fallback { |query| query.aggregate_rows("SUM", name, sum_cast(kind), distinct?) }
    if group_fields.empty?
      parse_sum(rows.first?.try(&.[1]), kind, zero)
    else
      grouped_values(rows, SumValue) { |value| parse_sum(value, kind, zero) }
    end
  end

  # The sum as exactly *type* (`Int64`, `Float64` or `BigDecimal`). Raises
  # `ArgumentError` on a grouped relation or when the sum has a fraction and
  # *type* is `Int64`. `BigDecimal` needs `require "grant/big_decimal"`.
  #
  # ```
  # Invoice.sum(:total, as: BigDecimal) # => 1250.75
  # ```
  def sum(column : Symbol | String, as type : T.class) : T forall T
    raise ArgumentError.new("sum(as:) returns one value; use sum(column) on a grouped relation") unless group_fields.empty?
    {% if T == Grant::Decimal128 %}
      if shape = exact_decimal_shape(column.to_s)
        total = exact_decimal_sum(column.to_s, shape[0], shape[1])
        return total if total.is_a?(Grant::Decimal128)
      end
    {% end %}
    return numeric_from_text("0", type) if is_none?

    if should_chunk_in?
      total = chunked_decimal_total(column.to_s)
      return numeric_from_text(total.to_s, type)
    end

    rows = with_index_hint_fallback { |query| query.aggregate_rows("SUM", column.to_s, sum_cast(numeric_kind(column.to_s)), distinct?) }
    value = rows.first?.try(&.[1])
    numeric_from_text(value.nil? ? "0" : value.to_s, type)
  end

  # The average of *column*, `nil` when no rows match. A grouped relation
  # returns a `Hash` per group.
  @[TypeOnce]
  def avg(column : Symbol | String) : AverageResult
    name = column.to_s
    if is_none?
      return group_fields.empty? ? nil : empty_aggregate_hash(Float64?)
    end

    if should_chunk_in?
      return chunked_average(name)
    end

    rows = with_index_hint_fallback { |query| query.aggregate_rows("AVG", name, :double, distinct?) }
    if group_fields.empty?
      average_value(rows.first?.try(&.[1]))
    else
      grouped_values(rows, Float64?) { |value| average_value(value) }
    end
  end

  @[TypeOnce]
  def average(column : Symbol | String) : AverageResult
    avg(column)
  end

  # The smallest value of *column*, `nil` when no rows match. A grouped relation
  # returns a `Hash` per group.
  @[TypeOnce]
  def min(column : Symbol | String) : ExtremumResult
    extremum("MIN", column.to_s)
  end

  @[TypeOnce]
  def minimum(column : Symbol | String) : ExtremumResult
    min(column)
  end

  # The largest value of *column*, `nil` when no rows match. A grouped relation
  # returns a `Hash` per group.
  @[TypeOnce]
  def max(column : Symbol | String) : ExtremumResult
    extremum("MAX", column.to_s)
  end

  @[TypeOnce]
  def maximum(column : Symbol | String) : ExtremumResult
    max(column)
  end

  # Runs one aggregate chosen at run time, like ActiveRecord's `calculate`.
  # *operation* is a `Grant::Calculation` or its symbol (`:count`, `:sum`,
  # `:average`/`:avg`, `:minimum`/`:min`, `:maximum`/`:max`). Every operation
  # except `:count` needs a *column*. The result type follows the named
  # method: `count` gives `Int64`, `sum` an exact number, and so on; grouped
  # relations give a `Hash`.
  #
  # ```
  # Order.calculate(:sum, :cents)
  # Order.group(:status).calculate(:count)
  # ```
  @[TypeOnce]
  def calculate(operation : Grant::Calculation | Symbol, column : Symbol | String? = nil) : CalculationResult
    calculation = operation.is_a?(Symbol) ? Grant::Calculation.from_symbol(operation) : operation
    if calculation.count?
      return column ? count(column) : count
    end

    target = column || raise ArgumentError.new("calculate(#{calculation.to_s.downcase}) needs a column")
    case calculation
    when .sum?     then sum(target)
    when .average? then avg(target)
    when .minimum? then min(target)
    else                max(target)
    end
  end

  # Executes one aggregate statement (no IN-chunking) and returns its
  # `{group key, value}` rows.
  @[TypeOnce]
  protected def aggregate_rows(function : String, column : String, cast : Symbol, distinct : Bool) : AggregateRows
    aggregate_assembler = assembler
    sql = aggregate_assembler.aggregate_sql(function, column, cast, distinct)
    Grant::Query::Executor::Aggregate(Model).new(sql, aggregate_assembler.numbered_parameters, group_fields.size).run
  end

  @[TypeOnce]
  private def extremum(function : String, column : String) : ExtremumResult
    if is_none?
      return group_fields.empty? ? nil : {} of Grant::Columns::Type => Grant::Columns::Type
    end

    if should_chunk_in?
      raise ArgumentError.new("#{function.downcase} with grouped chunked IN lists is not supported") unless group_fields.empty?
      best : Grant::Columns::Type = nil
      each_in_chunk do |chunk_query|
        value = chunk_query.aggregate_rows(function, column, :none, false).first?.try(&.[1])
        next if value.nil?
        best = value if best.nil? || better_extremum?(function, value, best)
      end
      return best
    end

    rows = with_index_hint_fallback { |query| query.aggregate_rows(function, column, :none, false) }
    if group_fields.empty?
      rows.first?.try(&.[1])
    else
      grouped_values(rows, Grant::Columns::Type) { |value| value }
    end
  end

  @[TypeOnce]
  private def better_extremum?(function : String, candidate : Grant::Columns::Type, current : Grant::Columns::Type) : Bool
    ordering = compare_values(candidate, current)
    function == "MIN" ? ordering < 0 : ordering > 0
  end

  # `Hash` of group key to block-converted value: keyed by the value itself for
  # one GROUP BY column, by the array of values for several.
  private def grouped_values(rows : AggregateRows, type : V.class, & : Grant::Columns::Type -> V) forall V
    if group_fields.size == 1
      result = {} of Grant::Columns::Type => V
      rows.each { |key, value| result[key.first] = yield value }
      result
    else
      result = {} of Array(Grant::Columns::Type) => V
      rows.each { |key, value| result[key] = yield value }
      result
    end
  end

  private def empty_aggregate_hash(type : V.class) forall V
    if group_fields.size == 1
      {} of Grant::Columns::Type => V
    else
      {} of Array(Grant::Columns::Type) => V
    end
  end

  @[TypeOnce]
  private def empty_aggregate_count : CountResult
    group_fields.empty? ? 0_i64 : empty_group_count
  end

  @[TypeOnce]
  private def count_of_rows(rows : AggregateRows) : Int64
    value = rows.first?.try(&.[1])
    value.is_a?(Int) ? value.to_i64 : 0_i64
  end

  # ---- exact numeric results ------------------------------------------------

  # `:integer`, `:float` or `:unknown` from the declared type of *column* on this
  # model. Read at compile time from the column annotations, so a sum of an
  # `Int64` column never passes through `Float64`.
  @[TypeOnce]
  private def numeric_kind(column : String) : Symbol
    parts = column.split('.')
    return :unknown unless parts.size == 1 || (parts.size == 2 && parts[0] == Model.table_name)

    {% begin %}
    case parts.last
    {% for ivar in Model.instance_vars %}
      {% ann = ivar.annotation(Grant::Column) %}
      {% if ann && !ann[:converter] %}
        {% column_type = ann[:setter_type].resolve %}
    when {{ivar.name.stringify}}
        {% if column_type <= Int %}
      :integer
        {% elsif column_type <= Float %}
      :float
        {% else %}
      :unknown
        {% end %}
      {% end %}
    {% end %}
    else
      :unknown
    end
    {% end %}
  end

  # `{precision, scale}` of *column* when it is a `Grant::Decimal128` or
  # `Grant::Money` column of this model, else nil.
  @[TypeOnce]
  private def exact_decimal_shape(column : String) : {Int32, Int32}?
    parts = column.split('.')
    return unless parts.size == 1 || (parts.size == 2 && parts[0] == Model.table_name)

    {% begin %}
  case parts.last
  {% for ivar in Model.instance_vars %}
    {% ann = ivar.annotation(Grant::Column) %}
    {% if ann && ann[:exact_decimal] %}
  when {{ivar.name.stringify}}
    { {{ann[:precision]}}, {{ann[:scale]}} }
    {% end %}
  {% end %}
  else
    nil
  end
  {% end %}
  end

  # The exact sum of a decimal column at its *scale*. PostgreSQL and MySQL
  # sum NUMERIC/DECIMAL exactly; SQLite sums an `INTEGER` coefficient column
  # exactly (an overflow past Int64 is an error, never a rounded total). A
  # SQLite `TEXT` column (precision 19 to 38) would sum as REAL there, so its
  # values are read and added as `Grant::Decimal128`, which raises
  # `Grant::Decimal128::OverflowError` past 38 digits.
  @[TypeOnce]
  private def exact_decimal_sum(column : String, precision : Int32, scale : Int32) : SumResult
    zero = Grant::Decimal128.new(0, scale)
    if is_none?
      return group_fields.empty? ? zero : empty_aggregate_hash(SumValue)
    end

    stored_as_integer = Model.adapter.sqlite? && precision <= 18
    if Model.adapter.sqlite? && !stored_as_integer
      raise ArgumentError.new("sum of #{column} on a grouped relation is not exact on SQLite (a TEXT decimal column); sum each group's rows") unless group_fields.empty?
      total = zero
      pluck(column).each do |row|
        value = row.first
        total += Grant::Decimal128.parse(value.to_s).rescale(scale) unless value.nil?
      end
      return total
    end

    if should_chunk_in?
      raise ArgumentError.new("sum with a chunked IN list cannot preserve group, limit, offset or distinct") if group_fields.any? || @limit || @offset || distinct?
      total = zero
      each_in_chunk do |chunk_query|
        text = chunk_query.aggregate_rows("SUM", column, :text, false).first?.try(&.[1])
        total += exact_decimal_from_sum_text(text, scale, stored_as_integer)
      end
      return total
    end

    rows = with_index_hint_fallback { |query| query.aggregate_rows("SUM", column, :text, distinct?) }
    if group_fields.empty?
      exact_decimal_from_sum_text(rows.first?.try(&.[1]), scale, stored_as_integer)
    else
      grouped_values(rows, SumValue) { |value| exact_decimal_from_sum_text(value, scale, stored_as_integer).as(SumValue) }
    end
  end

  @[TypeOnce]
  private def exact_decimal_from_sum_text(value : Grant::Columns::Type, scale : Int32, stored_as_integer : Bool) : Grant::Decimal128
    return Grant::Decimal128.new(0, scale) if value.nil?
    text = value.to_s
    if stored_as_integer
      coefficient = text.to_i128? || raise ArgumentError.new("SUM returned #{text.inspect} for an INTEGER decimal column")
      Grant::Decimal128.new(coefficient, scale)
    else
      Grant::Decimal128.parse(text).rescale(scale)
    end
  end

  @[TypeOnce]
  private def zero_sum(kind : Symbol) : SumValue
    kind == :float ? 0.0 : 0_i64
  end

  # Float columns are summed natively; the rest come back as text so no digit
  # passes through a Float64.
  @[TypeOnce]
  private def sum_cast(kind : Symbol) : Symbol
    kind == :float ? :none : :text
  end

  @[TypeOnce]
  private def parse_sum(value : Grant::Columns::Type, kind : Symbol, zero : SumValue) : SumValue
    case value
    when Float then value.to_f64
    when Int   then value.to_i64
    when String
      {% if Grant::BIG_DECIMAL_SUPPORT %}
        value.to_i64? || BigDecimal.new(value)
      {% else %}
        value.to_i64? || value.to_f64
      {% end %}
    else zero
    end
  end

  @[TypeOnce]
  private def average_value(value : Grant::Columns::Type) : Float64?
    value.is_a?(Float) ? value.to_f64 : nil
  end

  # Converts the database's text form of a number to exactly *type*.
  private def numeric_from_text(text : String, type : T.class) : T forall T
    {% if T == Int64 %}
      {% if Grant::BIG_DECIMAL_SUPPORT %}
        text.to_i64? || begin
          decimal = BigDecimal.new(text)
          raise ArgumentError.new("#{text} does not fit Int64 exactly") unless decimal == decimal.trunc && decimal.abs <= Int64::MAX
          decimal.to_i64
        end
      {% else %}
        text.to_i64? || whole_number_from_decimal_text(text)
      {% end %}
    {% elsif T == Float64 %}
      text.to_f64
    {% elsif T == Grant::Decimal128 %}
      Grant::Decimal128.parse?(text) || raise ArgumentError.new("#{text} is not a decimal")
    {% elsif T.stringify == "BigDecimal" && Grant::BIG_DECIMAL_SUPPORT %}
      BigDecimal.new(text)
    {% elsif T.stringify == "BigDecimal" %}
      {% raise "sum(as: BigDecimal) needs Grant's BigDecimal support: add `require \"grant/big_decimal\"` before `require \"grant\"`." %}
    {% else %}
      {% raise "sum(as:) takes Int64, Float64, Grant::Decimal128 or BigDecimal, not #{T}" %}
    {% end %}
  end

  {% unless Grant::BIG_DECIMAL_SUPPORT %}
    # The `Int64` a decimal text with an all-zero fraction stands for
    # (`"1250.00"` is 1250). Raises `ArgumentError` for any other text.
    private def whole_number_from_decimal_text(text : String) : Int64
      whole, _, fraction = text.partition('.')
      value = whole.to_i64?
      if value && fraction.each_char.all?('0')
        value
      else
        raise ArgumentError.new("#{text} does not fit Int64 exactly")
      end
    end
  {% end %}

  # ---- IN-list chunking -----------------------------------------------------

  {% if Grant::BIG_DECIMAL_SUPPORT %}
    # The running total of the chunk sums: an exact decimal.
    private alias ChunkTotal = BigDecimal

    private def empty_chunk_total : ChunkTotal
      BigDecimal.new(0)
    end

    private def add_chunk_sum(total : ChunkTotal, sum_text : String) : ChunkTotal
      total + BigDecimal.new(sum_text)
    end
  {% else %}
    # The running total of the chunk sums. Without `grant/big_decimal` it is
    # an exact `Int64` while every chunk sum is a whole number and the total
    # stays in range, and a `Float64` from then on.
    private alias ChunkTotal = Int64 | Float64

    private def empty_chunk_total : ChunkTotal
      0_i64
    end

    private def add_chunk_sum(total : ChunkTotal, sum_text : String) : ChunkTotal
      chunk_sum = sum_text.to_i64?
      if total.is_a?(Int64) && chunk_sum
        whole_total = total.to_i128 + chunk_sum
        return whole_total.to_i64 if Int64::MIN <= whole_total <= Int64::MAX
      end
      total.to_f64 + sum_text.to_f64
    end
  {% end %}

  @[TypeOnce]
  private def chunked_decimal_total(column : String) : ChunkTotal
    if group_fields.any? || @limit || @offset || distinct?
      raise ArgumentError.new("sum with a chunked IN list cannot preserve group, limit, offset or distinct")
    end
    total = empty_chunk_total
    each_in_chunk do |chunk_query|
      text = chunk_query.aggregate_rows("SUM", column, :text, false).first?.try(&.[1])
      total = add_chunk_sum(total, text) if text.is_a?(String)
    end
    total
  end

  @[TypeOnce]
  private def chunked_sum(column : String, kind : Symbol, zero : SumValue) : SumValue
    total = chunked_decimal_total(column)
    {% if Grant::BIG_DECIMAL_SUPPORT %}
      kind == :float ? total.to_f64 : (total.to_s.to_i64? || total)
    {% else %}
      kind == :float ? total.to_f64 : total
    {% end %}
  end

  @[TypeOnce]
  private def chunked_average(column : String) : Float64?
    if group_fields.any? || @limit || @offset || distinct?
      raise ArgumentError.new("avg with a chunked IN list cannot preserve group, limit, offset or distinct")
    end
    total = empty_chunk_total
    counted = 0_i64
    each_in_chunk do |chunk_query|
      sum_text = chunk_query.aggregate_rows("SUM", column, :text, false).first?.try(&.[1])
      total = add_chunk_sum(total, sum_text) if sum_text.is_a?(String)
      counted += count_of_rows(chunk_query.aggregate_rows("COUNT", column, :none, false))
    end
    counted.zero? ? nil : total.to_f64 / counted
  end
end
