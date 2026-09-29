module Grant::Schema
  # One way a model's declared columns disagree with the database.
  struct Drift
    enum Kind
      MissingTable
      MissingColumn
      TypeMismatch
      PrimaryKeyMismatch
      # Strict only: a table column no `column` declares.
      UndeclaredColumn
      # Strict only: declared non-nilable, but the column allows NULL.
      NullableColumn
    end

    getter kind : Kind
    getter table_name : String
    getter column_name : String?
    getter message : String

    def initialize(@kind : Kind, @table_name : String, @column_name : String?, @message : String)
    end
  end

  # Raised by `Model.verify_schema!` when a model and its table disagree.
  class DriftError < Grant::ErrorBase
    getter model_name : String
    getter drift : Array(Drift)

    def initialize(@model_name : String, @drift : Array(Drift))
      super("#{@model_name} does not match its table: #{@drift.map(&.message).join("; ")}")
    end
  end

  # What a `column` declaration says, captured at compile time.
  # :nodoc:
  struct DeclaredColumn
    getter name : String
    # The Crystal type without its `Nil` part.
    getter type_name : String
    getter nilable : Bool
    getter primary : Bool
    # Converters and explicit `column_type:` make the SQL type unknowable here.
    getter opaque : Bool

    def initialize(@name : String, @type_name : String, @nilable : Bool, @primary : Bool, @opaque : Bool)
    end

    # Whether a database column of *family* can hold this Crystal type.
    def compatible_with?(family : TypeFamily) : Bool
      return true if opaque || family.other?
      case type_name
      when "Int8", "Int16", "Int32", "Int64", "Int128", "UInt8", "UInt16", "UInt32", "UInt64", "UInt128"
        family.integer?
      when "Bool"
        family.boolean? || family.integer?
      when "Float32", "Float64", "BigDecimal"
        family.float? || family.decimal?
      when "String"
        family.string? || family.text? || family.uuid? || family.json?
      when "UUID"
        family.uuid? || family.string?
      when "Time"
        family.date_time? || family.date? || family.time?
      when "Bytes", "Slice(UInt8)"
        family.binary?
      when "JSON::Any"
        family.json? || family.text? || family.string?
      else
        true
      end
    end
  end

  # :nodoc:
  class Verifier
    def initialize(@schema : Introspection, @table : String, @declared : Array(DeclaredColumn), @strict : Bool)
    end

    def drift : Array(Drift)
      found = Array(Drift).new
      unless @schema.table_exists?(@table)
        found << Drift.new(Drift::Kind::MissingTable, @table, nil, "table #{@table} is missing")
        return found
      end

      actual = @schema.columns(@table).index_by(&.name)
      @declared.each do |declared|
        unless info = actual[declared.name]?
          found << Drift.new(Drift::Kind::MissingColumn, @table, declared.name, "column #{@table}.#{declared.name} is missing")
          next
        end
        unless declared.compatible_with?(info.type_family)
          found << Drift.new(Drift::Kind::TypeMismatch, @table, declared.name,
            "#{@table}.#{declared.name} is #{info.sql_type} but declared #{declared.type_name}")
        end
        if @strict && info.null? && !declared.nilable && !declared.primary
          found << Drift.new(Drift::Kind::NullableColumn, @table, declared.name,
            "#{@table}.#{declared.name} allows NULL but is declared #{declared.type_name}")
        end
      end

      declared_keys = @declared.select(&.primary).map(&.name).sort!
      actual_keys = @schema.primary_key(@table).sort
      if !declared_keys.empty? && declared_keys != actual_keys
        found << Drift.new(Drift::Kind::PrimaryKeyMismatch, @table, nil,
          "#{@table} primary key is [#{actual_keys.join(", ")}] but declared [#{declared_keys.join(", ")}]")
      end

      if @strict
        names = @declared.map(&.name).to_set
        actual.each_key do |name|
          next if names.includes?(name)
          found << Drift.new(Drift::Kind::UndeclaredColumn, @table, name, "column #{@table}.#{name} is not declared")
        end
      end
      found
    end
  end
end

abstract class Grant::Base
  # The columns this model declares, for `Grant::Schema` drift checks.
  # :nodoc:
  def self.declared_schema_columns : Array(Grant::Schema::DeclaredColumn)
    {% begin %}
      [
        {% for ivar in @type.instance_vars.select(&.annotation(Grant::Column)) %}
          {% ann = ivar.annotation(Grant::Column) %}
          Grant::Schema::DeclaredColumn.new(
            {{ivar.name.stringify}},
            {{ivar.type.union_types.reject { |t| t == Nil }.first.stringify}},
            {{ann[:nilable] ? true : false}},
            {{ann[:primary] ? true : false}},
            {{(ann[:converter] || ann[:column_type]) ? true : false}}),
        {% end %}
      ] of Grant::Schema::DeclaredColumn
    {% end %}
  end

  # True when this model's table exists.
  def self.table_exists? : Bool
    adapter.schema.table_exists?(table_name)
  end

  # True when this model's table has *name*.
  def self.column_exists?(name : String | Symbol) : Bool
    adapter.schema.column_exists?(table_name, name)
  end

  # The database's columns for this model's table, from the schema cache.
  def self.database_columns : Array(Grant::Schema::ColumnInfo)
    adapter.schema.columns(table_name)
  end

  # The database's indexes for this model's table, from the schema cache.
  def self.database_indexes : Array(Grant::Schema::IndexInfo)
    adapter.schema.indexes(table_name)
  end

  # The database's foreign keys for this model's table, from the schema cache.
  def self.database_foreign_keys : Array(Grant::Schema::ForeignKeyInfo)
    adapter.schema.foreign_keys(table_name)
  end

  # Differences between this model's columns and its table. *strict* also
  # reports undeclared columns and nullable columns declared non-nilable.
  def self.verify_schema(strict : Bool = false) : Array(Grant::Schema::Drift)
    adapter.schema.verify(self, strict)
  end

  # Raises `Grant::Schema::DriftError` when the model and its table disagree.
  def self.verify_schema!(strict : Bool = false) : Nil
    adapter.schema.verify!(self, strict)
  end
end
