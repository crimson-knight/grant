require "./index_definition"

module Grant::Schema
  # The referential actions and deferral modes the constraint DSL accepts.
  module ConstraintOptions
    ACTIONS = {cascade: "CASCADE", restrict: "RESTRICT", nullify: "SET NULL", set_null: "SET NULL",
               set_default: "SET DEFAULT", no_action: "NO ACTION"}

    def self.action_sql(action : Symbol, what : ::String) : ::String
      ACTIONS[action]? || raise InvalidDefinition.new("Unknown #{what} #{action.inspect}; use #{ACTIONS.keys.join(", ")}")
    end

    # `DEFERRABLE INITIALLY ...` text for `deferrable:` (`true`, `:immediate`,
    # `:deferred`), or nil. Only PostgreSQL defers constraints.
    def self.deferrable_sql(dialect : Dialect, deferrable : Bool | Symbol?, name : ::String) : ::String?
      return if deferrable.nil? || deferrable == false
      raise UnsupportedOperation.new("Only PostgreSQL supports deferrable constraints ('#{name}')") unless dialect.pg?
      case deferrable
      when :deferred        then "DEFERRABLE INITIALLY DEFERRED"
      when :immediate, true then "DEFERRABLE INITIALLY IMMEDIATE"
      else                       raise InvalidDefinition.new("Unknown deferrable: #{deferrable.inspect}; use true, :immediate or :deferred")
      end
    end
  end

  # A foreign key from `table(columns)` to `to_table(primary_key)`.
  class ForeignKeyDefinition
    getter table : ::String
    getter to_table : ::String
    getter columns : Array(::String)
    getter primary_key : Array(::String)
    getter name : ::String
    getter on_delete : Symbol?
    getter on_update : Symbol?
    getter deferrable : Bool | Symbol?
    getter? validate : Bool

    def initialize(@table : ::String, @to_table : ::String, @columns : Array(::String), @primary_key : Array(::String),
                   name : ::String? = nil, @on_delete : Symbol? = nil, @on_update : Symbol? = nil,
                   @deferrable : Bool | Symbol? = nil, @validate : Bool = true)
      @name = name || Naming.constraint_name("fk", @table, @columns.join("_"))
    end

    # Builds the definition with ActiveRecord's defaults: the column is
    # `<singular to_table>_id` and the key is `id`.
    def self.build(table : TableName, to_table : TableName, column : ColumnNames? = nil, primary_key : ColumnNames? = nil,
                   name : ::String | Symbol? = nil, on_delete : Symbol? = nil, on_update : Symbol? = nil,
                   deferrable : Bool | Symbol? = nil, validate : Bool = true) : ForeignKeyDefinition
      columns = column ? IndexDefinition.to_names(column) : [Naming.foreign_key_column(to_table)]
      keys = primary_key ? IndexDefinition.to_names(primary_key) : ["id"]
      new(table.to_s, to_table.to_s, columns, keys, name.try(&.to_s), on_delete, on_update, deferrable, validate)
    end

    # `FOREIGN KEY (...) REFERENCES ...` with actions, without `CONSTRAINT name`
    # and without `NOT VALID`.
    def definition_sql(dialect : Dialect) : ::String
      String.build do |io|
        io << "FOREIGN KEY (" << @columns.map { |column| dialect.quote(column) }.join(", ") << ") REFERENCES "
        io << dialect.quote(@to_table) << " (" << @primary_key.map { |column| dialect.quote(column) }.join(", ") << ')'
        if on_delete = @on_delete
          io << " ON DELETE " << ConstraintOptions.action_sql(on_delete, "on_delete:")
        end
        if on_update = @on_update
          io << " ON UPDATE " << ConstraintOptions.action_sql(on_update, "on_update:")
        end
        if clause = ConstraintOptions.deferrable_sql(dialect, @deferrable, @name)
          io << ' ' << clause
        end
      end
    end

    def constraint_sql(dialect : Dialect) : ::String
      "CONSTRAINT #{dialect.quote(@name)} #{definition_sql(dialect)}"
    end

    # The column-level form `REFERENCES ...`, for `ALTER TABLE ADD COLUMN` on
    # SQLite.
    def inline_sql(dialect : Dialect) : ::String
      definition_sql(dialect).sub(/\AFOREIGN KEY \([^)]*\) /, "")
    end
  end

  # `CHECK (expression)`.
  class CheckConstraintDefinition
    getter table : ::String
    getter expression : ::String
    getter name : ::String
    getter? validate : Bool

    def initialize(@table : ::String, @expression : ::String, name : ::String? = nil, @validate : Bool = true)
      @name = name || Naming.constraint_name("chk", @table, Naming.digest(@expression))
    end

    def constraint_sql(dialect : Dialect) : ::String
      "CONSTRAINT #{dialect.quote(@name)} CHECK (#{@expression})"
    end
  end

  # `UNIQUE (columns)`, optionally deferrable or built on an existing index.
  class UniqueConstraintDefinition
    getter table : ::String
    getter columns : Array(::String)
    getter name : ::String
    getter deferrable : Bool | Symbol?
    getter using_index : ::String?

    def initialize(@table : ::String, @columns : Array(::String), name : ::String? = nil,
                   @deferrable : Bool | Symbol? = nil, @using_index : ::String? = nil)
      @name = name || Naming.constraint_name("uniq", @table, @columns.join("_"))
    end

    def constraint_sql(dialect : Dialect) : ::String
      String.build do |io|
        io << "CONSTRAINT " << dialect.quote(@name) << " UNIQUE "
        if index = @using_index
          raise UnsupportedOperation.new("using_index: is only supported on PostgreSQL ('#{@name}')") unless dialect.pg?
          io << "USING INDEX " << dialect.quote(index)
        else
          io << '(' << @columns.map { |column| dialect.quote(column) }.join(", ") << ')'
        end
        if clause = ConstraintOptions.deferrable_sql(dialect, @deferrable, @name)
          io << ' ' << clause
        end
      end
    end
  end

  # `EXCLUDE USING method (expression WITH operator)`, PostgreSQL only.
  class ExclusionConstraintDefinition
    getter table : ::String
    getter expression : ::String
    getter using : ::String?
    getter where : ::String?
    getter name : ::String
    getter deferrable : Bool | Symbol?

    def initialize(@table : ::String, @expression : ::String, @using : ::String? = nil, @where : ::String? = nil,
                   name : ::String? = nil, @deferrable : Bool | Symbol? = nil)
      @name = name || Naming.constraint_name("excl", @table, Naming.digest(@expression))
    end

    def constraint_sql(dialect : Dialect) : ::String
      raise UnsupportedOperation.new("Exclusion constraints are only supported on PostgreSQL ('#{@name}')") unless dialect.pg?
      String.build do |io|
        io << "CONSTRAINT " << dialect.quote(@name) << " EXCLUDE "
        io << "USING " << @using << ' ' if @using
        io << '(' << @expression << ')'
        io << " WHERE (" << @where << ')' if @where
        if clause = ConstraintOptions.deferrable_sql(dialect, @deferrable, @name)
          io << ' ' << clause
        end
      end
    end
  end
end
