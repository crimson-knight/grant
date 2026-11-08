require "json"
require "./builder"
require "../schema/gin_index"

# Predicates for database-specific column types: PostgreSQL arrays and JSON
# documents (jsonb on PostgreSQL, JSON text on SQLite).
#
# Every array operator binds the whole array as one parameter (`tags @> $1`),
# never one placeholder per element, and every JSON predicate compiles to the
# database's own operator (`@>`, `#>>`, `json_extract`) so a GIN or expression
# index applies. Nothing is filtered in Crystal.
#
# PostgreSQL supports both families. SQLite supports the JSON family through
# its JSON1 functions; arrays have no SQLite representation and raise
# `Grant::Schema::UnsupportedOperation`, as does MySQL for both.
class Grant::Query::Builder(Model)
  # Keeps rows whose array column contains every element of *values*
  # (`tags @> ARRAY[...]`).
  # ```
  # Post.where.array_contains(:tags, ["crystal", "orm"])
  # ```
  def array_contains!(field : Symbol | String, values : Grant::Columns::SupportedArrayTypes) : self
    add_array_predicate(field, "@>", values)
  end

  # Keeps rows whose array column shares at least one element with *values*
  # (`tags && ARRAY[...]`).
  def array_overlaps!(field : Symbol | String, values : Grant::Columns::SupportedArrayTypes) : self
    add_array_predicate(field, "&&", values)
  end

  # Keeps rows whose array column is contained in *values* (`tags <@ ARRAY[...]`).
  def array_contained_by!(field : Symbol | String, values : Grant::Columns::SupportedArrayTypes) : self
    add_array_predicate(field, "<@", values)
  end

  # Keeps rows whose array column holds *value* (`$1 = ANY(tags)`).
  def array_any!(field : Symbol | String, value : Grant::Columns::Type) : self
    require_array_support("array_any")
    predicate = "? = ANY(#{structured_field_sql(field.to_s)})"
    own_where_fields << {join: :and, stmt: predicate, values: [value.as(Grant::Columns::Type)]}
    self
  end

  # Keeps rows whose array column has a number of elements that compares to
  # *length* by *operator* (`:eq`, `:ne`, `:lt`, `:lte`, `:gt`, `:gte`;
  # `cardinality(tags) >= $1`). An empty array counts as 0 and a NULL column
  # never matches. The length is bound, not interpolated.
  # ```
  # Post.where.array_length(:tags, 3)
  # Post.where.array_length(:tags, 0, :gt)
  # ```
  def array_length!(field : Symbol | String, length : Int, operator : Symbol = :eq) : self
    require_array_support("array_length")
    sql_operator = ARRAY_LENGTH_OPERATORS[operator]? || raise ArgumentError.new("Unknown array_length operator #{operator.inspect}; use #{ARRAY_LENGTH_OPERATORS.keys.join(", ")}")
    predicate = "cardinality(#{structured_field_sql(field.to_s)}) #{sql_operator} ?"
    own_where_fields << {join: :and, stmt: predicate, values: [length.to_i32.as(Grant::Columns::Type)]}
    self
  end

  # Appends *value* to the array column of every matching row, in one
  # `UPDATE ... SET tags = array_append(tags, $1)`. Returns the rows changed.
  # A NULL column becomes a one-element array.
  # ```
  # Post.where(id: 1).array_append_all(:tags, "crystal")
  # ```
  def array_append_all(field : Symbol | String, value : Grant::Columns::Type) : Int64
    array_rewrite_all(field, "array_append", value)
  end

  # Removes every occurrence of *value* from the array column of every matching
  # row (`array_remove(tags, $1)`). Returns the rows changed.
  def array_remove_all(field : Symbol | String, value : Grant::Columns::Type) : Int64
    array_rewrite_all(field, "array_remove", value)
  end

  # :ditto:
  def array_length(field : Symbol | String, length : Int, operator : Symbol = :eq) : self
    dup.array_length!(field, length, operator)
  end

  # :ditto:
  def array_contains(field : Symbol | String, values : Grant::Columns::SupportedArrayTypes) : self
    dup.array_contains!(field, values)
  end

  # :ditto:
  def array_overlaps(field : Symbol | String, values : Grant::Columns::SupportedArrayTypes) : self
    dup.array_overlaps!(field, values)
  end

  # :ditto:
  def array_contained_by(field : Symbol | String, values : Grant::Columns::SupportedArrayTypes) : self
    dup.array_contained_by!(field, values)
  end

  # :ditto:
  def array_any(field : Symbol | String, value : Grant::Columns::Type) : self
    dup.array_any!(field, value)
  end

  # Keeps rows whose JSON column contains the *document* (`settings @> '{"theme":"dark"}'`).
  # *document* is anything that serializes to JSON: a `JSON::Any`, a hash or a
  # named tuple. MySQL runs `JSON_CONTAINS`; on SQLite the containment is
  # expanded into `json_extract` and `json_each` tests.
  # ```
  # User.where.json_contains(:settings, {theme: "dark"})
  # ```
  def json_contains!(field : Symbol | String, document) : self
    add_json_containment(:and, field.to_s, document)
    self
  end

  # The containment `json_contains` adds, joined with *join* (`:and` or `:or`).
  #
  # :nodoc:
  def add_json_containment(join : Symbol, field : String, document) : Nil
    add_json_containment_text(join, field, document.to_json)
  end

  # `where(settings: {theme: "dark"})` on a JSON column: the same containment
  # as `json_contains`, joined with *join*. Called by `where` when the value is
  # a hash or named tuple and the key names a JSON column.
  #
  # `where` instantiates this for every nested hash, also for one that names a
  # joined table (`where(posts: {id: 1_i64..})`), whose values may have no JSON
  # form. So the document is written value by value instead of with `to_json`,
  # and a value that is not JSON raises `ArgumentError` when it is used.
  #
  # :nodoc:
  def add_json_condition(join : Symbol, field : String, conditions : Hash | NamedTuple) : Nil
    json = ::JSON.build { |builder| write_json_condition(builder, conditions) }
    add_json_containment_text(join, field, json)
  end

  private def write_json_condition(json : ::JSON::Builder, value : Hash | NamedTuple) : Nil
    json.object do
      value.each { |key, item| json.field(key.to_s) { write_json_condition(json, item) } }
    end
  end

  private def write_json_condition(json : ::JSON::Builder, value : Array | Tuple) : Nil
    json.array do
      value.each { |item| write_json_condition(json, item) }
    end
  end

  private def write_json_condition(json : ::JSON::Builder, value : Bool | String | Symbol | Number | Enum | Time | UUID | ::JSON::Any | ::JSON::Serializable?) : Nil
    value.to_json(json)
  end

  private def write_json_condition(json : ::JSON::Builder, value) : Nil
    raise ArgumentError.new("A #{value.class} cannot be part of a JSON document condition")
  end

  private def add_json_containment_text(join : Symbol, field : String, json : String) : Nil
    column = structured_field_sql(field)
    case @relation_state.db_type
    in .pg?
      own_where_fields << {join: join, stmt: "#{column} @> ?::jsonb", values: [json.as(Grant::Columns::Type)]}
    in .sqlite?
      clauses = [] of String
      binds = [] of Grant::Columns::Type
      sqlite_containment(column, ::JSON.parse(json), "$", clauses, binds, 0)
      own_where_fields << {join: join, stmt: "(#{clauses.join(" AND ")})", values: binds}
    in .mysql?
      own_where_fields << {join: join, stmt: "JSON_CONTAINS(#{column}, CAST(? AS JSON))", values: [json.as(Grant::Columns::Type)]}
    end
  end

  # True when *field* is a `JSON::Any` column of the model.
  #
  # :nodoc:
  def json_document_column?(field : String) : Bool
    {% begin %}
      case field
      {% for ivar in Model.instance_vars %}
        {% if ivar.annotation(Grant::Column) && ivar.type.union_types.any? { |member| member == JSON::Any } %}
      when {{ ivar.name.stringify }} then true
        {% end %}
      {% end %}
      else false
      end
    {% end %}
  end

  # Keeps rows whose JSON column holds *value* at *path*. The path is a list
  # of keys (array indexes as digits) or a dotted string; the comparison uses
  # `#>>` on PostgreSQL and `JSON_UNQUOTE(JSON_EXTRACT(...))` on MySQL (both
  # text) and `json_extract` on SQLite (typed).
  # ```
  # User.where.json_path(:settings, "theme", "dark")
  # User.where.json_path(:settings, %w(notifications email), true)
  # ```
  def json_path!(field : Symbol | String, path : String | Array(String), value : String | Int | Float | Bool?) : self
    column = structured_field_sql(field.to_s)
    segments = path.is_a?(String) ? path.split('.') : path
    raise ArgumentError.new("json_path needs at least one path segment") if segments.empty? || segments.any?(&.empty?)

    case @relation_state.db_type
    in .pg?
      predicate, binds = pg_json_path_predicate(column, segments, value)
    in .sqlite?
      predicate, binds = sqlite_json_path_predicate(column, json_path_expression(segments), value)
    in .mysql?
      predicate, binds = mysql_json_path_predicate(column, json_path_expression(segments), value)
    end
    own_where_fields << {join: :and, stmt: predicate, values: binds}
    self
  end

  # Keeps rows whose JSON object column has the top-level *key*
  # (`settings ? 'theme'` on PostgreSQL, `JSON_CONTAINS_PATH` on MySQL,
  # `json_type(settings, '$."theme"')` on SQLite).
  def json_has_key!(field : Symbol | String, key : String) : self
    column = structured_field_sql(field.to_s)
    case @relation_state.db_type
    in .pg?
      own_where_fields << {join: :and, stmt: "#{column} ?? ?", values: [key.as(Grant::Columns::Type)]}
    in .sqlite?
      own_where_fields << {join: :and, stmt: "json_type(#{column}, ?) IS NOT NULL", values: [json_path_expression([key]).as(Grant::Columns::Type)]}
    in .mysql?
      own_where_fields << {join: :and, stmt: "JSON_CONTAINS_PATH(#{column}, 'one', ?) = 1", values: [json_path_expression([key]).as(Grant::Columns::Type)]}
    end
    self
  end

  # :ditto:
  def json_contains(field : Symbol | String, document) : self
    dup.json_contains!(field, document)
  end

  # :ditto:
  def json_path(field : Symbol | String, path : String | Array(String), value : String | Int | Float | Bool?) : self
    dup.json_path!(field, path, value)
  end

  # :ditto:
  def json_has_key(field : Symbol | String, key : String) : self
    dup.json_has_key!(field, key)
  end

  ARRAY_LENGTH_OPERATORS = {eq: "=", ne: "<>", lt: "<", lte: "<=", gt: ">", gte: ">="}

  private def array_rewrite_all(field : Symbol | String, function : String, value : Grant::Columns::Type) : Int64
    require_array_support(function)
    return 0_i64 if is_none?

    Model.guard_writes!
    raise ArgumentError.new("#{function} cannot chunk an IN list") if should_chunk_in?
    structured_field_sql(field.to_s)
    column = Model.quote(field.to_s)

    built = assembler
    placeholder = built.add_parameter(value)
    sql = Grant::QueryLogs.append(built.update_all_fragment_sql("#{column} = #{function}(#{column}, #{placeholder})"))
    Model.mark_write_operation

    adapter = Model.adapter
    adapter.open(sql, built.numbered_parameters, Model.name) do |db|
      db.exec(sql, args: adapter.normalize_bind_values(built.numbered_parameters)).rows_affected
    end
  end

  private def add_array_predicate(field : Symbol | String, operator : String, values : Grant::Columns::SupportedArrayTypes) : self
    require_array_support("array operators")
    predicate = "#{structured_field_sql(field.to_s)} #{operator} ?"
    own_where_fields << {join: :and, stmt: predicate, values: [values.as(Grant::Columns::Type)]}
    self
  end

  private def require_array_support(what : String) : Nil
    return if @relation_state.db_type.pg?
    raise Grant::Schema::UnsupportedOperation.new("#{what} need PostgreSQL array columns; #{@relation_state.db_type.to_s.upcase} has no array type")
  end

  private def pg_json_path_predicate(column : String, segments : Array(String), value) : Tuple(String, Array(Grant::Columns::Type))
    path = segments.as(Grant::Columns::Type)
    if value.nil?
      {"(#{column} #>> ?) IS NULL", [path]}
    else
      {"(#{column} #>> ?) = ?", [path, value.to_s.as(Grant::Columns::Type)]}
    end
  end

  # Like PostgreSQL's `#>>`, a JSON null and a missing path both read as NULL.
  private def mysql_json_path_predicate(column : String, path : String, value) : Tuple(String, Array(Grant::Columns::Type))
    if value.nil?
      {"COALESCE(JSON_TYPE(JSON_EXTRACT(#{column}, ?)), 'NULL') = 'NULL'", [path.as(Grant::Columns::Type)]}
    else
      {"JSON_UNQUOTE(JSON_EXTRACT(#{column}, ?)) = ?", [path.as(Grant::Columns::Type), value.to_s.as(Grant::Columns::Type)]}
    end
  end

  private def sqlite_json_path_predicate(column : String, path : String, value) : Tuple(String, Array(Grant::Columns::Type))
    case value
    when Nil
      {"json_extract(#{column}, ?) IS NULL", [path.as(Grant::Columns::Type)]}
    when Bool
      {"json_type(#{column}, ?) = ?", [path.as(Grant::Columns::Type), value.to_s]}
    when Int
      {"json_extract(#{column}, ?) = ?", [path.as(Grant::Columns::Type), value.to_i64]}
    when Float
      {"json_extract(#{column}, ?) = ?", [path.as(Grant::Columns::Type), value.to_f64]}
    else
      {"json_extract(#{column}, ?) = ?", [path.as(Grant::Columns::Type), value.to_s]}
    end
  end

  # `$.a[0]."b c"` for the segments `a`, `0`, `b c`: the path syntax SQLite
  # and MySQL share.
  private def json_path_expression(segments : Array(String)) : String
    String.build do |io|
      io << '$'
      segments.each { |segment| io << sqlite_json_segment(segment) }
    end
  end

  private def sqlite_json_segment(segment : String) : String
    return "[#{segment}]" if segment.each_char.all?(&.ascii_number?) && !segment.empty?
    raise ArgumentError.new("Invalid JSON path segment #{segment.inspect}") if segment.includes?('"')
    ".\"#{segment}\""
  end

  # Expands `col @> document` into one json_extract / json_each test per leaf.
  # An array in *document* needs, for each of its items, an element of the stored
  # array that contains it: a scalar item compares by type and value, an object
  # or array item recurses over the element's JSON text, under its own
  # `json_each` alias (*depth* keeps the aliases of nested arrays apart).
  private def sqlite_containment(column : String, document : ::JSON::Any, path : String, clauses : Array(String), binds : Array(Grant::Columns::Type), depth : Int32) : Nil
    case raw = document.raw
    when Hash
      if raw.empty?
        clauses << "json_type(#{column}, ?) = 'object'"
        binds << path
      end
      raw.each do |key, child|
        raise ArgumentError.new("Invalid JSON key #{key.inspect}") if key.includes?('"')
        sqlite_containment(column, child, "#{path}.\"#{key}\"", clauses, binds, depth)
      end
    when Array
      clauses << "json_type(#{column}, ?) = 'array'"
      binds << path
      raw.each do |item|
        scalar = item.raw
        alias_name = "grant_je#{depth}"
        if scalar.is_a?(Hash) || scalar.is_a?(Array)
          inner = [] of String
          binds_for_inner = [] of Grant::Columns::Type
          sqlite_containment("#{alias_name}.value", item, "$", inner, binds_for_inner, depth + 1)
          # A bare scalar element is not JSON text, so the CASE keeps the nested
          # tests away from it (they would fail with "malformed JSON").
          kind = scalar.is_a?(Hash) ? "object" : "array"
          clauses << "EXISTS (SELECT 1 FROM json_each(#{column}, ?) AS #{alias_name} WHERE CASE WHEN #{alias_name}.type = '#{kind}' THEN (#{inner.join(" AND ")}) ELSE 0 END)"
          binds << path
          binds.concat(binds_for_inner)
        else
          clauses << "EXISTS (SELECT 1 FROM json_each(#{column}, ?) AS #{alias_name} WHERE #{alias_name}.type = ? AND #{alias_name}.value IS ?)"
          binds << path
          binds << sqlite_json_type(scalar)
          binds << sqlite_json_value(scalar)
        end
      end
    when Nil
      clauses << "json_type(#{column}, ?) = 'null'"
      binds << path
    when Bool
      clauses << "json_type(#{column}, ?) = ?"
      binds << path
      binds << raw.to_s
    else
      clauses << "json_extract(#{column}, ?) = ?"
      binds << path
      binds << sqlite_json_value(raw)
    end
  end

  private def sqlite_json_type(value) : String
    case value
    when Nil   then "null"
    when Bool  then value.to_s
    when Int   then "integer"
    when Float then "real"
    else            "text"
    end
  end

  private def sqlite_json_value(value) : Grant::Columns::Type
    case value
    when Nil   then nil
    when Bool  then value ? 1_i64 : 0_i64
    when Int   then value.to_i64
    when Float then value.to_f64
    else            value.to_s
    end
  end
end
