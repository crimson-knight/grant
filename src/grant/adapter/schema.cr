require "big"
require "../../adapter/base"

module Grant::Schema
  # Raised when a schema statement is asked for something the adapter's
  # database cannot express (for example `array: true` outside PostgreSQL).
  class UnsupportedOperation < Grant::ErrorBase
  end

  # Raised when a table or column definition is inconsistent, before any SQL
  # is sent to the database.
  class InvalidDefinition < Grant::ErrorBase
  end

  # A Crystal value usable as a SQL column default.
  alias DefaultLiteral = ::String | Int8 | Int16 | Int32 | Int64 | Float32 | Float64 | BigDecimal | Bool | ::Time | Nil

  # The SQL flavor a schema statement is written in. Statements are built from
  # a dialect alone, so the SQL for every adapter can be asserted without a
  # connection to it.
  enum Dialect
    Sqlite
    Pg
    Mysql

    # Returns the dialect of *adapter*.
    def self.for(adapter : Grant::Adapter::Base) : Dialect
      if adapter.postgres?
        Pg
      elsif adapter.mysql?
        Mysql
      elsif adapter.sqlite?
        Sqlite
      else
        raise UnsupportedOperation.new("Schema statements are not supported by the #{adapter.adapter_name} adapter")
      end
    end

    def quote_char : Char
      mysql? ? '`' : '"'
    end

    # Quotes a table or column name, doubling embedded quote characters. A
    # dotted name is quoted per part (`schema.table`).
    def quote(name : String | Symbol) : String
      char = quote_char
      String.build do |io|
        name.to_s.split('.').each_with_index do |part, index|
          io << '.' unless index == 0
          io << char << part.gsub(char, "#{char}#{char}") << char
        end
      end
    end

    # Quotes a value as a SQL literal.
    def quote_literal(value : DefaultLiteral) : String
      case value
      in Nil                                                     then "NULL"
      in Bool                                                    then value ? "TRUE" : "FALSE"
      in Int8, Int16, Int32, Int64, Float32, Float64, BigDecimal then value.to_s
      in Time                                                    then "'#{value.to_utc.to_s("%F %T.%6N")}'"
      in String
        escaped = value.gsub("'", "''")
        escaped = escaped.gsub("\\", "\\\\") if mysql?
        "'#{escaped}'"
      end
    end

    # Renders a SQL expression default. PostgreSQL takes it verbatim; MySQL and
    # SQLite need parentheses around anything that is not a bare
    # `CURRENT_TIMESTAMP` style keyword.
    def default_expression(expression : String) : String
      return expression if pg?
      trimmed = expression.strip
      return trimmed if trimmed.starts_with?('(') && trimmed.ends_with?(')')
      bare = mysql? ? /\A(CURRENT_TIMESTAMP|CURRENT_DATE|CURRENT_TIME|NOW|LOCALTIMESTAMP|LOCALTIME)(\(\d*\))?\z/i : /\ACURRENT_(TIMESTAMP|DATE|TIME)\z/i
      trimmed.matches?(bare) ? trimmed : "(#{trimmed})"
    end

    # Like `#default_expression` for a column of native type *type*. MySQL
    # refuses `DEFAULT CURRENT_TIMESTAMP` on `DATETIME(6)` unless the default
    # carries the same number of fractional digits, so a bare time keyword
    # takes them from the column type.
    def default_expression(expression : String, type : String) : String
      rendered = default_expression(expression)
      return rendered unless mysql?
      digits = type.match(/\A(?:DATETIME|TIMESTAMP|TIME)\((\d+)\)/i).try(&.[1])
      return rendered if digits.nil? || digits == "0"
      rendered.match(/\A(CURRENT_TIMESTAMP|CURRENT_TIME|NOW|LOCALTIMESTAMP|LOCALTIME)\z/i) ? "#{rendered}(#{digits})" : rendered
    end
  end

  # Native column types for Crystal types that the adapters' own `Schema::TYPES`
  # tables do not cover, plus the refinement of a mapped type by `limit`,
  # `precision` and `scale`. Adapter tables win where they define a key, so
  # existing generated SQL does not change.
  module TypeCatalog
    PG = {
      "Int8"       => "SMALLINT",
      "Int16"      => "SMALLINT",
      "Bytes"      => "BYTEA",
      "Date"       => "DATE",
      "JSON::Any"  => "JSONB",
      "BigDecimal" => "NUMERIC",
    }

    SQLITE = {
      "Int8"       => "INTEGER",
      "Int16"      => "INTEGER",
      "Bytes"      => "BLOB",
      "Date"       => "DATE",
      "JSON::Any"  => "TEXT",
      "BigDecimal" => "NUMERIC",
    }

    MYSQL = {
      "Int8"       => "TINYINT",
      "Int16"      => "SMALLINT",
      "Bytes"      => "BLOB",
      "Date"       => "DATE",
      "JSON::Any"  => "JSON",
      "BigDecimal" => "DECIMAL",
    }

    # Returns the native type for the Crystal type named *key*, or nil.
    def self.lookup(adapter : Grant::Adapter::Base, key : String) : String?
      adapter.class.schema_type?(key) || extras(Dialect.for(adapter))[key]?
    end

    def self.extras(dialect : Dialect) : Hash(String, String)
      case dialect
      in .pg?     then PG
      in .mysql?  then MYSQL
      in .sqlite? then SQLITE
      end
    end

    # Applies `limit:`, `precision:` and `scale:` to the mapped *base* type of
    # the Crystal type *key*.
    def self.refine(dialect : Dialect, key : String, base : String, limit : Int32? = nil, precision : Int32? = nil, scale : Int32? = nil) : String
      case key
      when "String"
        limit ? "VARCHAR(#{limit})" : base
      when "BigDecimal"
        if precision
          "#{dialect.mysql? ? "DECIMAL" : "NUMERIC"}(#{precision}, #{scale || 0})"
        elsif scale
          raise InvalidDefinition.new("scale: #{scale} needs a precision:")
        else
          base
        end
      when "Time"
        precision && !dialect.sqlite? ? "#{base.sub(/\(\d+\)/, "")}(#{precision})" : base
      else
        base
      end
    end
  end
end
