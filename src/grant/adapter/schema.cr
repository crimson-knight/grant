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
      when "Int8", "Int16", "Int32", "Int64"
        limit ? integer_type(dialect, limit) : base
      when "Bytes"
        dialect.mysql? ? sized(base, {255 => "TINYBLOB", 65_535 => "BLOB", 16_777_215 => "MEDIUMBLOB"}, "LONGBLOB", limit) : base
      else
        base
      end
    end

    # The Crystal type that carries each native type name, per dialect, for
    # tools that turn a database column back into a model column (the
    # reverse of `lookup`). PostgreSQL extension types (`hstore`, `citext`,
    # `ltree`) and the network and money types have no Crystal type of their
    # own: they arrive as their text form, so a model declares them as `String`
    # with `column_type: "citext"` (the type is then emitted verbatim).
    CRYSTAL_PG = {
      "smallint" => "Int16", "int2" => "Int16", "integer" => "Int32", "int" => "Int32", "int4" => "Int32",
      "bigint" => "Int64", "int8" => "Int64", "real" => "Float32", "float4" => "Float32",
      "double precision" => "Float64", "float8" => "Float64", "numeric" => "BigDecimal", "decimal" => "BigDecimal",
      "boolean" => "Bool", "bool" => "Bool", "text" => "String", "character varying" => "String",
      "varchar" => "String", "character" => "String", "char" => "String", "bpchar" => "String", "name" => "String",
      "bytea" => "Bytes", "date" => "Time", "timestamp" => "Time", "timestamptz" => "Time",
      "timestamp without time zone" => "Time", "timestamp with time zone" => "Time", "time" => "Time",
      "uuid" => "UUID", "json" => "JSON::Any", "jsonb" => "JSON::Any",
      "hstore" => "String", "citext" => "String", "ltree" => "String", "inet" => "String", "cidr" => "String",
      "macaddr" => "String", "money" => "String",
    }

    CRYSTAL_MYSQL = {
      "tinyint" => "Int8", "smallint" => "Int16", "mediumint" => "Int32", "int" => "Int32", "integer" => "Int32",
      "bigint" => "Int64", "float" => "Float32", "double" => "Float64", "decimal" => "BigDecimal",
      "varchar" => "String", "char" => "String", "text" => "String", "tinytext" => "String",
      "mediumtext" => "String", "longtext" => "String", "blob" => "Bytes", "tinyblob" => "Bytes",
      "mediumblob" => "Bytes", "longblob" => "Bytes", "date" => "Time", "datetime" => "Time",
      "timestamp" => "Time", "time" => "Time", "json" => "JSON::Any",
    }

    CRYSTAL_SQLITE = {
      "integer" => "Int64", "int" => "Int32", "tinyint" => "Int8", "smallint" => "Int16", "bigint" => "Int64",
      "real" => "Float64", "float" => "Float32", "double" => "Float64", "numeric" => "BigDecimal",
      "decimal" => "BigDecimal", "boolean" => "Bool", "text" => "String", "varchar" => "String",
      "char" => "String", "blob" => "Bytes", "date" => "Time", "datetime" => "Time", "timestamp" => "Time",
      "time" => "Time", "json" => "JSON::Any",
    }

    # The extension a PostgreSQL native type needs (`CREATE EXTENSION`), or nil
    # for the types built into the server.
    EXTENSIONS = {"hstore" => "hstore", "citext" => "citext", "ltree" => "ltree"}

    # The extension that provides the PostgreSQL type *native*, or nil.
    def self.extension_for(native : ::String) : ::String?
      EXTENSIONS[native.strip.downcase]?
    end

    # Returns the Crystal type name for the native type *native* of *dialect*
    # (`"numeric(12, 2)"` is `"BigDecimal"`, `"integer[]"` is `"Array(Int32)"`),
    # or nil when no Crystal type is mapped.
    def self.crystal_type(dialect : Dialect, native : ::String) : ::String?
      name = native.strip.downcase
      array = dialect.pg? && name.ends_with?("[]")
      name = name.rchop("[]") if array
      return "Bool" if dialect.mysql? && name.delete(' ') == "tinyint(1)"
      name = name.sub(/\s*\(.*\)/, "").strip
      table = case dialect
              in .pg?     then CRYSTAL_PG
              in .mysql?  then CRYSTAL_MYSQL
              in .sqlite? then CRYSTAL_SQLITE
              end
      found = table[name]?
      return nil unless found
      array ? "Array(#{found})" : found
    end

    # The integer type for ActiveRecord's byte-width *limit* (1 to 8).
    def self.integer_type(dialect : Dialect, limit : Int32) : ::String
      case dialect
      in .pg?
        raise InvalidDefinition.new("No integer type has limit: #{limit}") unless 1 <= limit <= 8
        limit <= 2 ? "SMALLINT" : (limit <= 4 ? "INTEGER" : "BIGINT")
      in .mysql?
        case limit
        when 1    then "TINYINT"
        when 2    then "SMALLINT"
        when 3    then "MEDIUMINT"
        when 4    then "INT"
        when 5..8 then "BIGINT"
        else           raise InvalidDefinition.new("No integer type has limit: #{limit}")
        end
      in .sqlite?
        case limit
        when 1    then "TINYINT"
        when 2    then "SMALLINT"
        when 3, 4 then "INTEGER"
        when 5..8 then "BIGINT"
        else           raise InvalidDefinition.new("No integer type has limit: #{limit}")
        end
      end
    end

    # The first of MySQL's size *steps* that holds *limit*, else *largest*;
    # *default* without a limit.
    def self.sized(default : ::String, steps : Hash(Int32, ::String), largest : ::String, limit : Int32?) : ::String
      return default unless limit
      steps.each { |max, type| return type if limit <= max }
      largest
    end
  end
end
