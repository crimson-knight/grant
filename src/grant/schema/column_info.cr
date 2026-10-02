require "json"

module Grant::Schema
  # Coarse, adapter-independent classification of a database column type.
  # It exists so declared Crystal types can be compared with what the catalog
  # reports without every caller parsing `varchar(255)` or `numeric(10,2)`.
  enum TypeFamily
    Integer
    Float
    Decimal
    String
    Text
    Boolean
    DateTime
    Date
    Time
    Binary
    Json
    Uuid
    Other

    # Classifies a raw SQL type as the catalog reports it.
    def self.classify(sql_type : ::String) : TypeFamily
      type = sql_type.downcase.strip
      return Other if type.empty?
      return Boolean if type.starts_with?("bool") || type == "tinyint(1)"
      return Other if type.starts_with?("interval") || type.starts_with?("point")
      return Integer if type.matches?(/\A(?:(?:tiny|small|medium|big)?int(?:eger)?[248]?|serial[248]?|smallserial|bigserial)(?:\W|\z)/)
      return Decimal if type.starts_with?("numeric") || type.starts_with?("decimal") || type.starts_with?("money")
      return Float if type.starts_with?("float") || type.starts_with?("double") || type.starts_with?("real")
      return Uuid if type == "uuid"
      return Json if type.starts_with?("json")
      return Binary if type.includes?("blob") || type.starts_with?("bytea") || type.includes?("binary")
      return DateTime if type.starts_with?("timestamp") || type.starts_with?("datetime")
      return Date if type == "date"
      return Time if type.starts_with?("time")
      return Text if type.includes?("text") || type.includes?("clob")
      return String if type.includes?("char") || type == "citext" || type == "name" || type.starts_with?("enum")
      Other
    end
  end

  # One column of one table as the database catalog describes it.
  #
  # ```
  # column = Grant.schema.columns(:users).first
  # column.name        # => "id"
  # column.sql_type    # => "bigint"
  # column.type_family # => Grant::Schema::TypeFamily::Integer
  # ```
  struct ColumnInfo
    include JSON::Serializable

    getter table_name : String
    getter name : String
    # The type exactly as the catalog spells it (`character varying(120)`).
    getter sql_type : String
    getter null : Bool
    # The default as a SQL expression, or `nil` when the column has none.
    getter default : String?
    # 1-based position within the primary key, or 0 when not part of it.
    getter primary_key_position : Int32
    getter auto_increment : Bool
    # 1-based ordinal position within the table.
    getter position : Int32
    getter comment : String?

    def initialize(@table_name : String, @name : String, @sql_type : String, @null : Bool,
                   @default : String? = nil, @primary_key_position : Int32 = 0,
                   @auto_increment : Bool = false, @position : Int32 = 0,
                   @comment : String? = nil)
    end

    def null? : Bool
      @null
    end

    def primary_key? : Bool
      @primary_key_position > 0
    end

    def auto_increment? : Bool
      @auto_increment
    end

    def type_family : TypeFamily
      TypeFamily.classify(@sql_type)
    end

    # The length in parentheses for character types (`varchar(120)` => 120).
    def limit : Int32?
      return unless type_family.string?
      @sql_type[/\((\d+)\)/, 1]?.try(&.to_i)
    end

    # Total digits of a decimal type (`numeric(10,2)` => 10).
    def precision : Int32?
      return unless type_family.decimal?
      @sql_type[/\((\d+)(?:\s*,\s*\d+)?\)/, 1]?.try(&.to_i)
    end

    # Digits after the decimal point (`numeric(10,2)` => 2).
    def scale : Int32?
      return unless type_family.decimal?
      @sql_type[/\(\d+\s*,\s*(\d+)\)/, 1]?.try(&.to_i)
    end
  end

  # One non-primary-key index of a table.
  struct IndexInfo
    include JSON::Serializable

    getter table_name : String
    getter name : String
    # Indexed columns in key order. Expression entries carry the expression
    # text, and `expression?` is then true.
    getter columns : Array(String)
    getter unique : Bool
    # The WHERE predicate of a partial index.
    getter where : String?
    getter expression : Bool

    def initialize(@table_name : String, @name : String, @columns : Array(String),
                   @unique : Bool = false, @where : String? = nil, @expression : Bool = false)
    end

    def unique? : Bool
      @unique
    end

    def expression? : Bool
      @expression
    end

    def partial? : Bool
      !@where.nil?
    end
  end

  # What the database does to referencing rows when the referenced row changes.
  enum ReferentialAction
    NoAction
    Restrict
    Cascade
    SetNull
    SetDefault

    def self.parse(text : ::String?) : ReferentialAction
      case text.try(&.upcase.strip)
      when "CASCADE"     then Cascade
      when "RESTRICT"    then Restrict
      when "SET NULL"    then SetNull
      when "SET DEFAULT" then SetDefault
      else                    NoAction
      end
    end
  end

  # One foreign key constraint, possibly spanning several columns.
  struct ForeignKeyInfo
    include JSON::Serializable

    getter table_name : String
    # `nil` on SQLite, whose foreign keys are unnamed.
    getter name : String?
    getter columns : Array(String)
    getter to_table : String
    getter primary_key_columns : Array(String)
    getter on_update : ReferentialAction
    getter on_delete : ReferentialAction

    def initialize(@table_name : String, @name : String?, @columns : Array(String),
                   @to_table : String, @primary_key_columns : Array(String),
                   @on_update : ReferentialAction = ReferentialAction::NoAction,
                   @on_delete : ReferentialAction = ReferentialAction::NoAction)
    end

    # The referencing column of a single-column key.
    def column : String
      @columns.first
    end

    def composite? : Bool
      @columns.size > 1
    end
  end
end
