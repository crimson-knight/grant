# Grant::Sanitization
#
# == Security model
#
# Grant's PRIMARY and PREFERRED defense against SQL injection is **parameterized
# queries**. Every first-class query path (`where`, `find`, `find_by`, the query
# builder, and the adapter `insert`/`update`/`delete`/`select` methods) emits `?`
# placeholders that are bound by crystal-db at execution time. Bound parameters
# are never interpolated into the SQL text, so user-supplied values cannot alter
# query structure. **Use parameter binding wherever possible.**
#
# This module exists ONLY for the raw escape hatch: the rare case where a
# developer must assemble an inline SQL string (a fragment that cannot be
# expressed with `?` placeholders — e.g. a dynamic identifier, or an
# ActiveRecord-style condition array like `["age > ?", 18]` that is built before
# a placeholder-aware path is available). For those cases this module provides
# type-aware literal quoting that neutralizes injection.
#
# Mirrors ActiveRecord's `sanitize_sql_array` / `quote` / `quote_column_name`.
#
# ```
# # Preferred — let the driver bind the value:
# User.where("age > ?", 18)
#
# # Escape hatch — only when you must build an inline string:
# sql = Grant::Sanitization.sanitize_sql_array(["age > ?", 18], User.adapter)
# # => "age > 18"
# ```
#
# == Limitations
#
# `sanitize_sql_array` substitutes positional `?` placeholders left-to-right and
# is aware of `?` characters that appear inside single-quoted SQL string literals
# (e.g. `WHERE note = 'is it? maybe'`) — those are NOT treated as placeholders.
# It does not attempt to parse comments, dollar-quoted strings (PG `$$...$$`), or
# other adapter-specific literal forms; keep raw SQL fragments simple, or prefer
# the parameterized query API.
module Grant::Sanitization
  extend self

  # Raised when the number of `?` placeholders in a SQL fragment does not match
  # the number of bind values supplied to `sanitize_sql_array`.
  class WrongNumberOfArguments < ArgumentError
  end

  # Quotes *value* as a SQL literal suitable for inline interpolation.
  #
  # When an *adapter* is supplied, quoting that differs across databases
  # (booleans, identifier quote char) follows that adapter. Without an adapter,
  # portable defaults are used (booleans as `1`/`0`).
  #
  # - `Nil`      => `NULL`
  # - `String`   => single-quoted, embedded single quotes doubled (`'` -> `''`)
  # - `Bool`     => adapter-appropriate (`TRUE`/`FALSE` for PG/SQLite, `1`/`0` otherwise)
  # - `Number`   => `to_s` (no quoting; injection-safe because it is numeric)
  # - `Time`     => single-quoted UTC timestamp `'YYYY-MM-DD HH:MM:SS'`
  # - `Bytes`    => hex blob literal (`x'...'`)
  #
  # Raises `ArgumentError` for types that cannot be safely quoted.
  def quote(value, adapter : Grant::Adapter::Base? = nil) : String
    case value
    when Nil
      "NULL"
    when Bool
      quote_boolean(value, adapter)
    when Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64, Float32, Float64
      value.to_s
    when String
      quote_string(value)
    when Char
      quote_string(value.to_s)
    when Symbol
      quote_string(value.to_s)
    when Time
      quote_string(value.to_utc.to_s("%Y-%m-%d %H:%M:%S"))
    when Slice(UInt8)
      quote_bytes(value)
    else
      raise ArgumentError.new("Grant::Sanitization cannot quote value of type #{value.class}")
    end
  end

  # Escapes and single-quotes a String literal. Embedded single quotes are
  # doubled per the SQL standard, and any embedded NUL byte is stripped (it
  # terminates the C string the driver hands to the database and cannot appear
  # in a valid literal).
  def quote_string(value : String) : String
    escaped = value.gsub('\0', "").gsub("'", "''")
    "'#{escaped}'"
  end

  # Quotes a table or column identifier per *adapter*'s quoting character
  # (`"..."` for PG/SQLite, backticks for MySQL). Embedded quote characters are
  # doubled to prevent identifier-based injection. Falls back to double quotes
  # when no adapter is given.
  def quote_identifier(name, adapter : Grant::Adapter::Base? = nil) : String
    if adapter
      # Delegate to the adapter's own identifier quoting (the same routine used
      # to quote table/column names everywhere else in Grant), which doubles any
      # embedded quote character per adapter (`"` for PG/SQLite, backtick for
      # MySQL).
      adapter.quote(name.to_s)
    else
      # No adapter context: use standard SQL double-quote identifier quoting.
      escaped = name.to_s.gsub('"', "\"\"")
      "\"#{escaped}\""
    end
  end

  # ActiveRecord-style sanitization of a `[sql, *values]` array.
  #
  # Substitutes each positional `?` in *sql* (left to right) with the
  # corresponding quoted value from *values*. `?` characters inside single-quoted
  # SQL string literals are preserved verbatim and do NOT consume a bind value.
  #
  # Raises `WrongNumberOfArguments` if the count of placeholders does not match
  # the count of values.
  #
  # ```
  # Grant::Sanitization.sanitize_sql_array(["name = ? AND age > ?", "O'Brien", 30])
  # # => "name = 'O''Brien' AND age > 30"
  # ```
  def sanitize_sql_array(ary : Array, adapter : Grant::Adapter::Base? = nil) : String
    raise ArgumentError.new("sanitize_sql_array requires a non-empty array") if ary.empty?

    sql = ary.first.to_s
    values = ary[1..]

    placeholder_count = count_placeholders(sql)
    if placeholder_count != values.size
      raise WrongNumberOfArguments.new(
        "wrong number of bind variables (#{values.size} for #{placeholder_count}) in: #{sql}"
      )
    end

    return sql if placeholder_count == 0

    substitute_placeholders(sql, values, adapter)
  end

  # :ditto:
  def sanitize_sql_array(*args, adapter : Grant::Adapter::Base? = nil) : String
    sanitize_sql_array(args.to_a, adapter)
  end

  # Counts `?` placeholders in *sql*, ignoring any `?` that appears inside a
  # single-quoted string literal.
  private def count_placeholders(sql : String) : Int32
    count = 0
    in_string = false
    chars = sql.chars
    i = 0
    while i < chars.size
      c = chars[i]
      if c == '\''
        if in_string && i + 1 < chars.size && chars[i + 1] == '\''
          # Escaped quote ('') inside a literal — skip both.
          i += 2
          next
        end
        in_string = !in_string
      elsif c == '?' && !in_string
        count += 1
      end
      i += 1
    end
    count
  end

  # Replaces each placeholder `?` (outside single-quoted literals) with the next
  # quoted value, preserving the rest of the SQL verbatim.
  private def substitute_placeholders(sql : String, values : Array, adapter : Grant::Adapter::Base?) : String
    result = String::Builder.new
    in_string = false
    value_index = 0
    chars = sql.chars
    i = 0
    while i < chars.size
      c = chars[i]
      if c == '\''
        if in_string && i + 1 < chars.size && chars[i + 1] == '\''
          result << '\''
          result << '\''
          i += 2
          next
        end
        in_string = !in_string
        result << c
      elsif c == '?' && !in_string
        result << quote(values[value_index], adapter)
        value_index += 1
      else
        result << c
      end
      i += 1
    end
    result.to_s
  end

  private def quote_boolean(value : Bool, adapter : Grant::Adapter::Base?) : String
    if adapter
      # Delegate to the adapter so the literal matches the active database
      # (PG/SQLite => TRUE/FALSE, MySQL => 1/0).
      adapter.quote_boolean(value)
    else
      # No adapter context: 1/0 is accepted by every supported database.
      value ? "1" : "0"
    end
  end

  private def quote_bytes(value : Slice(UInt8)) : String
    "x'#{value.hexstring}'"
  end
end
