require "../adapter/schema"

module Grant::Schema
  # The column kinds of the create-table DSL. Each maps to one native type per
  # dialect (see `ColumnDefinition#sql_type`).
  enum ColumnKind
    String
    Text
    Integer
    SmallInt
    TinyInt
    BigInt
    Boolean
    Float
    Double
    Decimal
    DateTime
    Timestamp
    Time
    Date
    Binary
    Json
    Jsonb
    Uuid
  end

  # Marks "no `default:` given", so `default: nil` can mean `DEFAULT NULL`.
  struct Unset
  end

  UNSET = Unset.new

  # One column of a `TableDefinition`.
  class ColumnDefinition
    getter name : ::String
    getter type : ColumnKind | ::String
    property null : Bool
    property default : DefaultLiteral | Unset
    property default_sql : ::String?
    property limit : Int32?
    property precision : Int32?
    property scale : Int32?
    property comment : ::String?
    property collation : ::String?
    property? array : Bool
    property? primary_key : Bool
    # True for PostgreSQL-only native types (`citext`, `inet`, ...).
    property? pg_only : Bool = false

    def initialize(@name : ::String, @type : ColumnKind | ::String, @null : Bool = true,
                   @default : DefaultLiteral | Unset = UNSET, @default_sql : ::String? = nil,
                   @limit : Int32? = nil, @precision : Int32? = nil, @scale : Int32? = nil,
                   @comment : ::String? = nil, @collation : ::String? = nil,
                   @array : Bool = false, @primary_key : Bool = false)
    end

    # The native type of this column in *dialect*, with `limit`, `precision`,
    # `scale` and `array` applied. A raw SQL type string is used verbatim.
    def sql_type(dialect : Dialect) : ::String
      kind = @type
      if @pg_only && !dialect.pg?
        raise UnsupportedOperation.new("The #{kind} type of '#{@name}' is only supported on PostgreSQL")
      end
      if kind.is_a?(::String)
        raise UnsupportedOperation.new("array: true is only supported on PostgreSQL") if @array && !dialect.pg?
        return @array ? "#{kind}[]" : kind
      end
      native = native_type(dialect, kind)
      if @array
        raise UnsupportedOperation.new("array: true is only supported on PostgreSQL") unless dialect.pg?
        native += "[]"
      end
      native
    end

    # The column as it appears in `CREATE TABLE` / `ADD COLUMN`.
    def to_sql(dialect : Dialect) : ::String
      String.build do |io|
        io << dialect.quote(@name) << ' ' << sql_type(dialect)
        if collation = @collation
          io << " COLLATE " << (dialect.pg? ? dialect.quote(collation) : collation)
        end
        io << " NOT NULL" unless @null
        if clause = default_clause(dialect)
          io << ' ' << clause
        end
        if (text = @comment) && dialect.mysql?
          io << " COMMENT " << dialect.quote_literal(text)
        end
      end
    end

    # The `DEFAULT ...` clause, or nil when the column has no default.
    def default_clause(dialect : Dialect) : ::String?
      if expression = @default_sql
        return "DEFAULT #{dialect.default_expression(expression, sql_type(dialect))}"
      end
      value = @default
      return if value.is_a?(Unset)
      "DEFAULT #{dialect.quote_literal(value)}"
    end

    private def native_type(dialect : Dialect, kind : ColumnKind) : ::String
      case kind
      in .string?
        limit = @limit
        if limit
          "VARCHAR(#{limit})"
        else
          dialect.pg? ? "VARCHAR" : "VARCHAR(255)"
        end
      in .text?
        dialect.mysql? ? mysql_sized("TEXT", {255 => "TINYTEXT", 65_535 => "TEXT", 16_777_215 => "MEDIUMTEXT"}, "LONGTEXT") : "TEXT"
      in .integer?   then integer_type(dialect, @limit || 4)
      in .small_int? then integer_type(dialect, 2)
      in .tiny_int?  then integer_type(dialect, 1)
      in .big_int?   then integer_type(dialect, 8)
      in .boolean?
        dialect.mysql? ? "TINYINT(1)" : "BOOLEAN"
      in .float?
        dialect.pg? ? "REAL" : "FLOAT"
      in .double?
        dialect.pg? ? "DOUBLE PRECISION" : (dialect.mysql? ? "DOUBLE" : "REAL")
      in .decimal?
        precision = @precision
        scale = @scale
        raise InvalidDefinition.new("scale: #{scale} on '#{@name}' needs a precision:") if scale && !precision
        word = dialect.mysql? ? "DECIMAL" : "NUMERIC"
        precision ? "#{word}(#{precision}, #{scale || 0})" : word
      in .date_time?
        fraction = @precision || 6
        case dialect
        in .pg?     then "TIMESTAMP(#{fraction})"
        in .mysql?  then "DATETIME(#{fraction})"
        in .sqlite? then "DATETIME"
        end
      in .timestamp?
        fraction = @precision || 6
        dialect.sqlite? ? "TIMESTAMP" : "TIMESTAMP(#{fraction})"
      in .time?
        dialect.sqlite? ? "TIME" : "TIME(#{@precision || 6})"
      in .date?
        "DATE"
      in .binary?
        dialect.pg? ? "BYTEA" : (dialect.mysql? ? mysql_sized("BLOB", {255 => "TINYBLOB", 65_535 => "BLOB", 16_777_215 => "MEDIUMBLOB"}, "LONGBLOB") : "BLOB")
      in .json?
        "JSON"
      in .jsonb?
        raise UnsupportedOperation.new("jsonb columns are only supported on PostgreSQL ('#{@name}')") unless dialect.pg?
        "JSONB"
      in .uuid?
        dialect.pg? ? "UUID" : "CHAR(36)"
      end
    end

    private def integer_type(dialect : Dialect, limit : Int32) : ::String
      TypeCatalog.integer_type(dialect, limit)
    end

    private def mysql_sized(default : ::String, steps : Hash(Int32, ::String), largest : ::String) : ::String
      TypeCatalog.sized(default, steps, largest, @limit)
    end
  end

  # The block argument of `create_table`: collects the columns of one table.
  #
  # ```
  # statements.create_table(:users) do |t|
  #   t.string :name, null: false, limit: 100
  #   t.decimal :balance, precision: 12, scale: 2, default: 0
  #   t.timestamps precision: 6
  # end
  # ```
  class TableDefinition
    getter name : ::String
    getter columns = [] of ColumnDefinition

    def initialize(@name : ::String)
    end

    # Adds a column of *type*: a `ColumnKind`, its symbol (`:string`), or a raw
    # SQL type string used verbatim.
    def column(name : ::String | Symbol, type : ColumnKind | Symbol | ::String,
               null : Bool = true, default : DefaultLiteral | Unset = UNSET, default_sql : ::String? = nil,
               limit : Int32? = nil, precision : Int32? = nil, scale : Int32? = nil,
               comment : ::String? = nil, collation : ::String? = nil,
               array : Bool = false, primary_key : Bool = false) : ColumnDefinition
      kind = if type.is_a?(Symbol)
               ColumnKind.parse?(type.to_s) || raise InvalidDefinition.new("Unknown column type #{type.inspect} for '#{name}'")
             else
               type
             end
      if default_sql && !default.is_a?(Unset)
        raise InvalidDefinition.new("Column '#{name}' has both default: and default_sql:")
      end
      raise InvalidDefinition.new("Column '#{name}' is defined twice in '#{@name}'") if @columns.any? { |c| c.name == name.to_s }
      definition = ColumnDefinition.new(name.to_s, kind, null, default, default_sql, limit, precision, scale,
        comment, collation, array, primary_key || false)
      @columns << definition
      definition
    end

    {% for method, kind in {string: "String", text: "Text", integer: "Integer", smallint: "SmallInt", tinyint: "TinyInt",
                            bigint: "BigInt", boolean: "Boolean", float: "Float", double: "Double", decimal: "Decimal",
                            datetime: "DateTime", timestamp: "Timestamp", time: "Time", date: "Date", binary: "Binary",
                            json: "Json", jsonb: "Jsonb", uuid: "Uuid"} %}
      # Adds one or more `{{kind.id}}` columns.
      def {{method.id}}(*names : ::String | Symbol, null : Bool = true, default : DefaultLiteral | Unset = UNSET,
                        default_sql : ::String? = nil, limit : Int32? = nil, precision : Int32? = nil,
                        scale : Int32? = nil, comment : ::String? = nil, collation : ::String? = nil,
                        array : Bool = false, primary_key : Bool = false) : Nil
        names.each do |name|
          column(name, ColumnKind::{{kind.id}}, null, default, default_sql, limit, precision, scale,
            comment, collation, array, primary_key)
        end
      end
    {% end %}

    # Adds `created_at` and `updated_at`. Like ActiveRecord 8 they are
    # `NOT NULL` and carry microsecond precision unless told otherwise.
    def timestamps(null : Bool = false, precision : Int32? = 6, default : DefaultLiteral | Unset = UNSET,
                   default_sql : ::String? = nil) : Nil
      {"created_at", "updated_at"}.each do |name|
        column(name, ColumnKind::DateTime, null, default, default_sql, nil, precision)
      end
    end
  end
end
