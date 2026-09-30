require "./builder"

module Grant
  # Raised when a relation uses `with` / `with_recursive` on a database server
  # that has no common table expressions (MySQL below 8.0.1, MariaDB below
  # 10.2.1).
  class UnsupportedCommonTableExpressionError < Grant::ErrorBase
  end
end

# Helpers behind `with`, `with_recursive` and their depth guard.
module Grant::Query::CommonTableExpressions
  # The column `with_recursive` adds to a guarded CTE to count recursion levels.
  DEPTH_COLUMN = "grant_depth"

  # Recursion levels a guarded `with_recursive` allows unless told otherwise.
  DEFAULT_MAX_DEPTH = 1000

  # Words that cannot appear at the top level of a recursive term: databases
  # reject them there, and the depth guard cannot be placed around them.
  FORBIDDEN_STEP_WORDS = %w(GROUP ORDER LIMIT OFFSET FETCH HAVING WINDOW UNION INTERSECT EXCEPT FOR)

  # Raises `Grant::UnsupportedCommonTableExpressionError` unless *adapter*'s
  # server understands `WITH`.
  def self.ensure_supported!(adapter : Grant::Adapter::Base) : Nil
    return if adapter.supports_common_table_expressions?

    raise Grant::UnsupportedCommonTableExpressionError.new(
      "#{adapter.adapter_name} #{adapter.database_version} does not support common table expressions (WITH)")
  end

  # Returns the recursive term *step* with a depth counter added: the CTE's
  # `grant_depth` column grows by one per level and the term stops producing
  # rows once it reaches *max_depth*.
  #
  # *step* must be `SELECT <list> FROM <sources> [WHERE <condition>]`, the only
  # shape a recursive term may take; anything else raises `ArgumentError`.
  def self.guard_step(step : String, max_depth : Int32) : String
    raise ArgumentError.new("with_recursive: max_depth must be positive") unless max_depth > 0

    from_at = nil
    where_at = nil
    depth = 0
    quote : Char? = nil
    index = 0
    chars = step.chars

    while index < chars.size
      char = chars[index]
      if current = quote
        quote = nil if char == current
      elsif char == '\'' || char == '"' || char == '`'
        quote = char
      elsif char == '('
        depth += 1
      elsif char == ')'
        depth -= 1
      elsif depth == 0 && word_start?(chars, index)
        word = word_at(chars, index)
        upper = word.upcase
        if upper == "FROM" && from_at.nil?
          from_at = index
        elsif upper == "WHERE" && from_at && where_at.nil?
          where_at = index
        elsif from_at && FORBIDDEN_STEP_WORDS.includes?(upper)
          raise ArgumentError.new("with_recursive: the recursive term cannot contain #{upper} at its top level")
        end
        index += word.size - 1
      end
      index += 1
    end

    start = from_at
    raise ArgumentError.new("with_recursive: the recursive term must be SELECT ... FROM <cte> ...") if start.nil?

    counter = "#{DEPTH_COLUMN} + 1"
    limit = "#{DEPTH_COLUMN} < #{max_depth}"
    head = step[0, start].rstrip
    if where = where_at
      from_part = step[start, where - start]
      condition = step[(where + 5)..].strip
      "#{head}, #{counter} #{from_part}WHERE #{limit} AND (#{condition})"
    else
      "#{head}, #{counter} #{step[start..].rstrip} WHERE #{limit}"
    end
  end

  private def self.word_start?(chars : Array(Char), index : Int32) : Bool
    return false unless chars[index].ascii_letter?
    index == 0 || !(chars[index - 1].alphanumeric? || chars[index - 1] == '_')
  end

  private def self.word_at(chars : Array(Char), index : Int32) : String
    finish = index
    while finish < chars.size && (chars[finish].alphanumeric? || chars[finish] == '_')
      finish += 1
    end
    chars[index...finish].join
  end
end

class Grant::Query::Builder(Model)
  # One `WITH` entry. *render* produces the CTE body against the assembler that
  # is building the statement, so its binds take their place in that
  # statement's numbering.
  record CommonTable(Model), name : String, recursive : Bool, render : Proc(Grant::Query::Assembler::Base(Model), String)

  # Name of the FROM source set by `from`, or nil for the model's own table.
  @from_alias : String? = nil

  # Renders the FROM source against the statement's assembler (see `from`).
  @from_render : Proc(Grant::Query::Assembler::Base(Model), String)? = nil

  # How the FROM source is written: `:subquery` (parenthesized, aliased),
  # `:sql` (raw text) or `:table` (quoted name).
  @from_kind : Symbol = :none

  # CTEs added by `with` / `with_recursive`. Replaced, never mutated, so
  # relations that share it stay independent.
  @common_tables : Array(CommonTable(Model)) = [] of CommonTable(Model)

  # The alias of the `from` source, or nil.
  def from_alias : String?
    @from_alias
  end

  # Whether `from` replaced the model's table as the FROM source.
  def from_source? : Bool
    !@from_render.nil?
  end

  # :nodoc:
  def from_kind : Symbol
    @from_kind
  end

  # :nodoc:
  def from_render : Proc(Grant::Query::Assembler::Base(Model), String)?
    @from_render
  end

  # CTEs the relation carries, in the order they render.
  def common_tables : Array(CommonTable(Model))
    @common_tables
  end

  # Uses *source*, a relation, as the table the query selects from:
  # `FROM (SELECT ...) AS <name>`. *name* defaults to the model's table name,
  # so the model's own column qualifiers keep working. The subquery's bind
  # values come first, in numbered order, and it runs inside the outer
  # statement, never on its own.
  #
  # ```
  # adults = User.where("age >= ?", 18)
  # User.from(adults, as: "users").where(active: true)
  # # => SELECT ... FROM (SELECT ... WHERE age >= $1) AS "users" WHERE active = $2
  # ```
  def from!(source : Grant::Query::Builder, as name : String? = nil) : self
    alias_name = name || Model.table_name
    validate_identifier!(alias_name, "from")
    reset_load_state
    @from_kind = :subquery
    @from_alias = alias_name
    @from_render = subquery_renderer(source)
    self
  end

  # Uses the raw SQL *sql* as the FROM source, for example a view name or a
  # parenthesized subquery. *as* adds an alias. `?` placeholders in *sql* take
  # their values from *binds*.
  #
  # ```
  # User.from("(SELECT * FROM users WHERE age >= ?) recent", binds: [18_i64] of Grant::Columns::Type)
  # ```
  def from!(sql : String, as name : String? = nil, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : self
    validate_identifier!(name, "from") if name
    reset_load_state
    @from_kind = :sql
    @from_alias = name
    @from_render = ->(outer : Grant::Query::Assembler::Base(Model)) { outer.bind_fragment(sql, binds) }
    self
  end

  # Selects from the table or CTE *table* (quoted), optionally aliased.
  #
  # ```
  # User.with(:recent, User.where("age >= ?", 18)).from(:recent)
  # ```
  def from!(table : Symbol, as name : String? = nil) : self
    validate_identifier!(table.to_s, "from")
    validate_identifier!(name, "from") if name
    reset_load_state
    quoted = Model.quote(table.to_s)
    @from_kind = :table
    @from_alias = name
    @from_render = ->(outer : Grant::Query::Assembler::Base(Model)) { quoted }
    self
  end

  # Returns a copy that selects from another source. See `from!`.
  def from(source : Grant::Query::Builder, as name : String? = nil) : self
    chain_copy.from!(source, as: name)
  end

  # :ditto:
  def from(sql : String, as name : String? = nil, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : self
    chain_copy.from!(sql, as: name, binds: binds)
  end

  # :ditto:
  def from(table : Symbol, as name : String? = nil) : self
    chain_copy.from!(table, as: name)
  end

  # Drops the `from` source; the query reads the model's own table again.
  protected def clear_from_source! : Nil
    reset_load_state
    @from_kind = :none
    @from_alias = nil
    @from_render = nil
  end

  # Drops every CTE.
  protected def clear_common_tables! : Nil
    reset_load_state
    @common_tables = [] of CommonTable(Model)
  end

  # Adds the common table expression *name* AS (*query*), rendered as
  # `WITH "name" AS (...)` before the SELECT. Query it with `from(name)` or
  # refer to it from `where`/`joins` SQL. Its bind values come before the main
  # query's, in numbered order. Adding a CTE under an existing name replaces it.
  #
  # Raises `Grant::UnsupportedCommonTableExpressionError` when the statement is
  # built for a server without CTEs (MySQL below 8.0.1).
  #
  # ```
  # User.with(:adults, User.where("age >= ?", 18)).from(:adults).where(active: true)
  # # => WITH "adults" AS (SELECT ... WHERE age >= $1) SELECT ... FROM "adults" WHERE active = $2
  # ```
  def with!(name : Symbol | String, query : Grant::Query::Builder) : self
    add_common_table!(name, false, subquery_renderer(query))
  end

  # A CTE written as raw SQL; `?` placeholders take their values from *binds*.
  def with!(name : Symbol | String, sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : self
    add_common_table!(name, false, ->(outer : Grant::Query::Assembler::Base(Model)) { outer.bind_fragment(sql, binds) })
  end

  # Returns a copy with the CTE added. See `with!`.
  def with(name : Symbol | String, query : Grant::Query::Builder) : self
    chain_copy.with!(name, query)
  end

  # :ditto:
  def with(name : Symbol | String, sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : self
    chain_copy.with!(name, sql, binds)
  end

  # Adds a recursive CTE built from an *anchor* query and a recursive *step*,
  # joined by `UNION ALL` (`UNION` with `union_all: false`). The step is
  # `SELECT <list> FROM <cte> ... [WHERE <condition>]` (it refers to the CTE by
  # *name*) and may use `?` placeholders bound from *step_binds*.
  #
  # Runaway recursion is guarded: the CTE gets a `grant_depth` column (1 for
  # the anchor rows) and the step stops once it reaches *max_depth* levels
  # (default 1000), so a cycle in the data ends instead of looping forever.
  #
  # ```
  # tree = Node.with_recursive(:tree, Node.where(parent_id: nil),
  #   "SELECT nodes.* FROM nodes INNER JOIN tree ON nodes.parent_id = tree.id",
  #   max_depth: 20)
  # tree.from(:tree)
  # ```
  def with_recursive!(name : Symbol | String, anchor : Grant::Query::Builder | String, step : String, *,
                      max_depth : Int32 = Grant::Query::CommonTableExpressions::DEFAULT_MAX_DEPTH,
                      union_all : Bool = true,
                      anchor_binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type,
                      step_binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : self
    guarded = Grant::Query::CommonTableExpressions.guard_step(step, max_depth)
    anchor_render = anchor.is_a?(String) ? string_renderer(anchor, anchor_binds) : subquery_renderer(anchor)
    connector = union_all ? "UNION ALL" : "UNION"
    depth = Grant::Query::CommonTableExpressions::DEPTH_COLUMN
    render = ->(outer : Grant::Query::Assembler::Base(Model)) do
      anchor_sql = anchor_render.call(outer)
      step_sql = outer.bind_fragment(guarded, step_binds)
      "SELECT grant_anchor.*, 1 AS #{depth} FROM (#{anchor_sql}) AS grant_anchor #{connector} #{step_sql}"
    end
    add_common_table!(name, true, render)
  end

  # A recursive CTE written as one raw statement (`anchor UNION ALL step`),
  # with no depth guard. *unguarded* must be `true`: it states that the SQL
  # bounds its own recursion.
  def with_recursive!(name : Symbol | String, body : Grant::Query::Builder | String, *, unguarded : Bool,
                      binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : self
    raise ArgumentError.new("with_recursive: pass unguarded: true to use a recursive CTE without the depth guard") unless unguarded
    render = body.is_a?(String) ? string_renderer(body, binds) : subquery_renderer(body)
    add_common_table!(name, true, render)
  end

  # Returns a copy with the recursive CTE added. See `with_recursive!`.
  def with_recursive(name : Symbol | String, anchor : Grant::Query::Builder | String, step : String, *,
                     max_depth : Int32 = Grant::Query::CommonTableExpressions::DEFAULT_MAX_DEPTH,
                     union_all : Bool = true,
                     anchor_binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type,
                     step_binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : self
    chain_copy.with_recursive!(name, anchor, step, max_depth: max_depth, union_all: union_all,
      anchor_binds: anchor_binds, step_binds: step_binds)
  end

  # :ditto:
  def with_recursive(name : Symbol | String, body : Grant::Query::Builder | String, *, unguarded : Bool,
                     binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : self
    chain_copy.with_recursive!(name, body, unguarded: unguarded, binds: binds)
  end

  # Takes *other*'s `from` source and CTEs, as `merge` does for the other
  # clauses. A source on *other* wins; CTEs are added after this relation's own.
  #
  # :nodoc:
  protected def merge_from_and_with!(other : Grant::Query::Builder(Model)) : Nil
    if render = other.from_render
      @from_kind = other.from_kind
      @from_alias = other.from_alias
      @from_render = render
    end
    other.common_tables.each { |table| add_common_table!(table.name, table.recursive, table.render) }
  end

  private def add_common_table!(name : Symbol | String, recursive : Bool, render : Proc(Grant::Query::Assembler::Base(Model), String)) : self
    label = name.to_s
    validate_identifier!(label, "with")
    reset_load_state
    kept = @common_tables.reject { |table| table.name == label }
    @common_tables = kept + [CommonTable(Model).new(label, recursive, render)]
    self
  end

  # A renderer that embeds *source* as a subquery of the statement being built.
  # *source* is copied first, so later changes to it do not leak in.
  private def subquery_renderer(source : Grant::Query::Builder) : Proc(Grant::Query::Assembler::Base(Model), String)
    snapshot = source.dup
    ->(outer : Grant::Query::Assembler::Base(Model)) do
      inner = snapshot.assembler
      inner.share_parameters(outer.numbered_parameters)
      inner.select.raw_sql
    end
  end

  private def string_renderer(sql : String, binds : Array(Grant::Columns::Type)) : Proc(Grant::Query::Assembler::Base(Model), String)
    ->(outer : Grant::Query::Assembler::Base(Model)) { outer.bind_fragment(sql, binds) }
  end

  private def validate_identifier!(name : String, context : String) : Nil
    return if name.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
    raise ArgumentError.new("#{context}: #{name.inspect} is not a valid identifier")
  end

  private def validate_identifier!(name : Nil, context : String) : Nil
  end
end

module Grant::Query::BuilderMethods
  def from(source : Grant::Query::Builder, as name : String? = nil)
    __builder.from(source, as: name)
  end

  def from(sql : String, as name : String? = nil, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type)
    __builder.from(sql, as: name, binds: binds)
  end

  def from(table : Symbol, as name : String? = nil)
    __builder.from(table, as: name)
  end

  def with(name : Symbol | String, query : Grant::Query::Builder)
    __builder.with(name, query)
  end

  def with(name : Symbol | String, sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type)
    __builder.with(name, sql, binds)
  end

  def with_recursive(name : Symbol | String, anchor : Grant::Query::Builder | String, step : String, *,
                     max_depth : Int32 = Grant::Query::CommonTableExpressions::DEFAULT_MAX_DEPTH,
                     union_all : Bool = true,
                     anchor_binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type,
                     step_binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type)
    __builder.with_recursive(name, anchor, step, max_depth: max_depth, union_all: union_all,
      anchor_binds: anchor_binds, step_binds: step_binds)
  end

  def with_recursive(name : Symbol | String, body : Grant::Query::Builder | String, *, unguarded : Bool,
                     binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type)
    __builder.with_recursive(name, body, unguarded: unguarded, binds: binds)
  end
end
