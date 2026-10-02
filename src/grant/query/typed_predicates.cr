require "json"
require "./builder"

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
  # named tuple. On SQLite the containment is expanded into `json_extract`
  # comparisons; arrays inside the document may hold scalars only there.
  # ```
  # User.where.json_contains(:settings, {theme: "dark"})
  # ```
  def json_contains!(field : Symbol | String, document) : self
    column = structured_field_sql(field.to_s)
    json = document.to_json
    case @db_type
    in .pg?
      own_where_fields << {join: :and, stmt: "#{column} @> ?::jsonb", values: [json.as(Grant::Columns::Type)]}
    in .sqlite?
      clauses = [] of String
      binds = [] of Grant::Columns::Type
      sqlite_containment(column, ::JSON.parse(json), "$", clauses, binds)
      own_where_fields << {join: :and, stmt: "(#{clauses.join(" AND ")})", values: binds}
    in .mysql?
      raise_unsupported_json
    end
    self
  end

  # Keeps rows whose JSON column holds *value* at *path*. The path is a list
  # of keys (array indexes as digits) or a dotted string; the comparison uses
  # `#>>` on PostgreSQL (text) and `json_extract` on SQLite (typed).
  # ```
  # User.where.json_path(:settings, "theme", "dark")
  # User.where.json_path(:settings, %w(notifications email), true)
  # ```
  def json_path!(field : Symbol | String, path : String | Array(String), value : String | Int | Float | Bool | Nil) : self
    column = structured_field_sql(field.to_s)
    segments = path.is_a?(String) ? path.split('.') : path
    raise ArgumentError.new("json_path needs at least one path segment") if segments.empty? || segments.any?(&.empty?)

    case @db_type
    in .pg?
      predicate, binds = pg_json_path_predicate(column, segments, value)
    in .sqlite?
      predicate, binds = sqlite_json_path_predicate(column, sqlite_json_path(segments), value)
    in .mysql?
      raise_unsupported_json
    end
    own_where_fields << {join: :and, stmt: predicate, values: binds}
    self
  end

  # Keeps rows whose JSON object column has the top-level *key*
  # (`settings ? 'theme'` on PostgreSQL, `json_type(settings, '$."theme"')` on SQLite).
  def json_has_key!(field : Symbol | String, key : String) : self
    column = structured_field_sql(field.to_s)
    case @db_type
    in .pg?
      own_where_fields << {join: :and, stmt: "#{column} ?? ?", values: [key.as(Grant::Columns::Type)]}
    in .sqlite?
      own_where_fields << {join: :and, stmt: "json_type(#{column}, ?) IS NOT NULL", values: [sqlite_json_path([key]).as(Grant::Columns::Type)]}
    in .mysql?
      raise_unsupported_json
    end
    self
  end

  # :ditto:
  def json_contains(field : Symbol | String, document) : self
    dup.json_contains!(field, document)
  end

  # :ditto:
  def json_path(field : Symbol | String, path : String | Array(String), value : String | Int | Float | Bool | Nil) : self
    dup.json_path!(field, path, value)
  end

  # :ditto:
  def json_has_key(field : Symbol | String, key : String) : self
    dup.json_has_key!(field, key)
  end

  private def add_array_predicate(field : Symbol | String, operator : String, values : Grant::Columns::SupportedArrayTypes) : self
    require_array_support("array operators")
    predicate = "#{structured_field_sql(field.to_s)} #{operator} ?"
    own_where_fields << {join: :and, stmt: predicate, values: [values.as(Grant::Columns::Type)]}
    self
  end

  private def require_array_support(what : String) : Nil
    return if @db_type.pg?
    raise Grant::Schema::UnsupportedOperation.new("#{what} need PostgreSQL array columns; #{@db_type.to_s.upcase} has no array type")
  end

  private def raise_unsupported_json : NoReturn
    raise Grant::Schema::UnsupportedOperation.new("JSON predicates are supported on PostgreSQL and SQLite only")
  end

  private def pg_json_path_predicate(column : String, segments : Array(String), value) : Tuple(String, Array(Grant::Columns::Type))
    path = segments.as(Grant::Columns::Type)
    if value.nil?
      {"(#{column} #>> ?) IS NULL", [path]}
    else
      {"(#{column} #>> ?) = ?", [path, value.to_s.as(Grant::Columns::Type)]}
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

  # `$.a[0]."b c"` for the segments `a`, `0`, `b c`.
  private def sqlite_json_path(segments : Array(String)) : String
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
  private def sqlite_containment(column : String, document : ::JSON::Any, path : String, clauses : Array(String), binds : Array(Grant::Columns::Type)) : Nil
    case raw = document.raw
    when Hash
      if raw.empty?
        clauses << "json_type(#{column}, ?) = 'object'"
        binds << path
      end
      raw.each do |key, child|
        raise ArgumentError.new("Invalid JSON key #{key.inspect}") if key.includes?('"')
        sqlite_containment(column, child, "#{path}.\"#{key}\"", clauses, binds)
      end
    when Array
      clauses << "json_type(#{column}, ?) = 'array'"
      binds << path
      raw.each do |item|
        scalar = item.raw
        if scalar.is_a?(Hash) || scalar.is_a?(Array)
          raise Grant::Schema::UnsupportedOperation.new("SQLite json_contains cannot match objects or arrays inside an array")
        end
        clauses << "EXISTS (SELECT 1 FROM json_each(#{column}, ?) WHERE json_each.type = ? AND json_each.value IS ?)"
        binds << path
        binds << sqlite_json_type(scalar)
        binds << sqlite_json_value(scalar)
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
