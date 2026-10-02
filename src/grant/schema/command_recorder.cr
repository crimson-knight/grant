require "./schema_statements"

module Grant::Schema
  # Raised when a migration is rolled back through a step that has no inverse
  # (raw `execute`, `change_column`, `remove_columns`, ...). Write the rollback
  # by hand with `up`/`down` or `reversible`.
  class IrreversibleMigration < Grant::ErrorBase
    def initialize(message = "This migration cannot be reversed")
      super(message)
    end
  end

  # One recorded step: what to run going forward and, when one exists, what
  # undoes it. `inverse_name` is the name of the undoing command
  # (`"remove_column"` for `"add_column"`), for inspection and error messages.
  class Command
    alias Action = Proc(SchemaStatements, Nil)

    getter name : ::String
    getter inverse_name : ::String?

    def initialize(@name : ::String, @forward : Action, @inverse : Action?, @inverse_name : ::String? = nil)
    end

    def reversible? : Bool
      !@inverse.nil?
    end

    # Runs the step on *statements*.
    def apply(statements : SchemaStatements) : Nil
      @forward.call(statements)
    end

    # Runs what undoes the step; `IrreversibleMigration` when nothing does.
    def undo(statements : SchemaStatements) : Nil
      inverse = @inverse || raise IrreversibleMigration.new("#{@name} is not reversible")
      inverse.call(statements)
    end

    # The same step seen from the other side: forward and inverse swapped.
    def reversed : Command
      inverse = @inverse || raise IrreversibleMigration.new("#{@name} is not reversible")
      Command.new(@inverse_name || "revert_#{@name}", inverse, @forward, @name)
    end
  end

  # Records the schema calls a `change` method makes, each with its inverse,
  # instead of running them. `Migration#down` replays the recording backwards
  # to undo a migration. Recording is in memory and costs one small object per
  # call.
  #
  # An irreversible call (`execute`, `change_column`, ...) raises
  # `IrreversibleMigration` as soon as the recording is reversed, before any of
  # the inverse steps run, so a rollback never stops half way for that reason.
  class CommandRecorder
    getter commands = [] of Command
    getter? recording : Bool = false

    # Runs the block with recording on and returns what it recorded; calls
    # recorded before stay where they are.
    def capture(& : ->) : Array(Command)
      outer = @commands
      was_recording = @recording
      @commands = [] of Command
      @recording = true
      begin
        yield
        @commands
      ensure
        @commands = outer
        @recording = was_recording
      end
    end

    def add(command : Command) : Nil
      @commands << command
    end

    private def record(name : ::String, forward : Command::Action, inverse : Command::Action? = nil, inverse_name : ::String? = nil) : Nil
      @commands << Command.new(name, forward, inverse, inverse_name)
    end

    # ---- tables ----------------------------------------------------------

    def create_table(name : TableName, id : Bool | Symbol = true, primary_key : ColumnNames? = nil,
                     if_not_exists : Bool = false, temporary : Bool = false,
                     force : Bool | Symbol = false, comment : ::String? = nil,
                     options : ::String? = nil, &block : TableDefinition ->) : Nil
      record("create_table",
        ->(s : SchemaStatements) { s.create_table(name, id, primary_key, if_not_exists, temporary, force, comment, options) { |t| block.call(t) }; nil },
        ->(s : SchemaStatements) { s.drop_table(name, if_exists: if_not_exists); nil },
        "drop_table")
    end

    # Reversible only when given the block that recreates the table.
    def drop_table(name : TableName, if_exists : Bool = false, cascade : Bool = false, &block : TableDefinition ->) : Nil
      record("drop_table",
        ->(s : SchemaStatements) { s.drop_table(name, if_exists: if_exists, cascade: cascade); nil },
        ->(s : SchemaStatements) { s.create_table(name) { |t| block.call(t) }; nil },
        "create_table")
    end

    def drop_table(*names : TableName, if_exists : Bool = false, cascade : Bool = false) : Nil
      record("drop_table", ->(s : SchemaStatements) { s.drop_table(*names, if_exists: if_exists, cascade: cascade); nil })
    end

    def rename_table(old : TableName, new : TableName) : Nil
      record("rename_table",
        ->(s : SchemaStatements) { s.rename_table(old, new); nil },
        ->(s : SchemaStatements) { s.rename_table(new, old); nil }, "rename_table")
    end

    def create_join_table(first : TableName, second : TableName, table_name : TableName? = nil,
                          column_options : NamedTuple = NamedTuple.new, &block : TableDefinition ->) : Nil
      record("create_join_table",
        ->(s : SchemaStatements) { s.create_join_table(first, second, table_name, column_options) { |t| block.call(t) }; nil },
        ->(s : SchemaStatements) { s.drop_join_table(first, second, table_name); nil }, "drop_join_table")
    end

    def create_join_table(first : TableName, second : TableName, table_name : TableName? = nil,
                          column_options : NamedTuple = NamedTuple.new) : Nil
      record("create_join_table",
        ->(s : SchemaStatements) { s.create_join_table(first, second, table_name, column_options); nil },
        ->(s : SchemaStatements) { s.drop_join_table(first, second, table_name); nil }, "drop_join_table")
    end

    def drop_join_table(first : TableName, second : TableName, table_name : TableName? = nil, if_exists : Bool = false) : Nil
      record("drop_join_table",
        ->(s : SchemaStatements) { s.drop_join_table(first, second, table_name, if_exists: if_exists); nil },
        ->(s : SchemaStatements) { s.create_join_table(first, second, table_name); nil }, "create_join_table")
    end

    def add_timestamps(table : TableName, **options) : Nil
      record("add_timestamps",
        ->(s : SchemaStatements) { s.add_timestamps(table, **options); nil },
        ->(s : SchemaStatements) { s.remove_timestamps(table); nil }, "remove_timestamps")
    end

    def remove_timestamps(table : TableName) : Nil
      record("remove_timestamps",
        ->(s : SchemaStatements) { s.remove_timestamps(table); nil },
        ->(s : SchemaStatements) { s.add_timestamps(table, null: true); nil }, "add_timestamps")
    end

    # ---- columns ---------------------------------------------------------

    def add_column(table : TableName, name : ::String | Symbol, type : ColumnKind | Symbol | ::String, **options) : Nil
      record("add_column",
        ->(s : SchemaStatements) { s.add_column(table, name, type, **options); nil },
        ->(s : SchemaStatements) { s.remove_column(table, name, type); nil }, "remove_column")
    end

    # Reversible when the column's *type* is given.
    def remove_column(table : TableName, name : ::String | Symbol, type : ColumnKind | Symbol | ::String, if_exists : Bool = false, **options) : Nil
      record("remove_column",
        ->(s : SchemaStatements) { s.remove_column(table, name, type, if_exists: if_exists); nil },
        ->(s : SchemaStatements) { s.add_column(table, name, type, **options); nil }, "add_column")
    end

    def remove_column(table : TableName, name : ::String | Symbol, if_exists : Bool = false) : Nil
      record("remove_column", ->(s : SchemaStatements) { s.remove_column(table, name, if_exists: if_exists); nil })
    end

    def rename_column(table : TableName, old : ::String | Symbol, new : ::String | Symbol) : Nil
      record("rename_column",
        ->(s : SchemaStatements) { s.rename_column(table, old, new); nil },
        ->(s : SchemaStatements) { s.rename_column(table, new, old); nil }, "rename_column")
    end

    def change_column_null(table : TableName, column : ::String | Symbol, null : Bool, default : DefaultLiteral | Unset = UNSET) : Nil
      record("change_column_null",
        ->(s : SchemaStatements) { s.change_column_null(table, column, null, default); nil },
        ->(s : SchemaStatements) { s.change_column_null(table, column, !null); nil }, "change_column_null")
    end

    # Reversible when the previous default is given as *from*.
    def change_column_default(table : TableName, column : ::String | Symbol, to : DefaultLiteral | Unset = UNSET,
                              default_sql : ::String? = nil, from : DefaultLiteral | Unset = UNSET) : Nil
      inverse = if from.is_a?(Unset)
                  nil
                else
                  ->(s : SchemaStatements) { s.change_column_default(table, column, to: from); nil }
                end
      record("change_column_default",
        ->(s : SchemaStatements) { s.change_column_default(table, column, to, default_sql, from); nil },
        inverse, "change_column_default")
    end

    # ---- indexes ---------------------------------------------------------

    def add_index(table : TableName, columns : ColumnNames, **options) : Nil
      record("add_index",
        ->(s : SchemaStatements) { s.add_index(table, columns, **options); nil },
        ->(s : SchemaStatements) { s.remove_index(table, columns, name: options[:name]?); nil }, "remove_index")
    end

    # Reversible when the *columns* are given; every other option is the
    # `add_index` option that rebuilds the index.
    def remove_index(table : TableName, columns : ColumnNames, if_exists : Bool = false, algorithm : Symbol? = nil, **options) : Nil
      record("remove_index",
        ->(s : SchemaStatements) { s.remove_index(table, columns, name: options[:name]?, if_exists: if_exists, algorithm: algorithm); nil },
        ->(s : SchemaStatements) { s.add_index(table, columns, **options); nil }, "add_index")
    end

    def remove_index(table : TableName, name : ::String | Symbol, if_exists : Bool = false, algorithm : Symbol? = nil) : Nil
      record("remove_index", ->(s : SchemaStatements) { s.remove_index(table, name: name, if_exists: if_exists, algorithm: algorithm); nil })
    end

    def rename_index(table : TableName, old : ::String | Symbol, new : ::String | Symbol) : Nil
      record("rename_index",
        ->(s : SchemaStatements) { s.rename_index(table, old, new); nil },
        ->(s : SchemaStatements) { s.rename_index(table, new, old); nil }, "rename_index")
    end

    # ---- references, constraints -------------------------------------------

    def add_reference(table : TableName, *names : ::String | Symbol, **options) : Nil
      polymorphic = options[:polymorphic]? == true
      foreign_key = options[:foreign_key]? ? true : false
      record("add_reference",
        ->(s : SchemaStatements) { s.add_reference(table, *names, **options); nil },
        ->(s : SchemaStatements) { s.remove_reference(table, *names, polymorphic: polymorphic, foreign_key: foreign_key); nil }, "remove_reference")
    end

    def remove_reference(table : TableName, *names : ::String | Symbol, polymorphic : Bool = false, foreign_key : Bool = false) : Nil
      record("remove_reference",
        ->(s : SchemaStatements) { s.remove_reference(table, *names, polymorphic: polymorphic, foreign_key: foreign_key); nil },
        ->(s : SchemaStatements) { s.add_reference(table, *names, polymorphic: polymorphic, foreign_key: foreign_key); nil }, "add_reference")
    end

    def add_foreign_key(from_table : TableName, to_table : TableName, **options) : Nil
      record("add_foreign_key",
        ->(s : SchemaStatements) { s.add_foreign_key(from_table, to_table, **options); nil },
        ->(s : SchemaStatements) { s.remove_foreign_key(from_table, to_table, column: options[:column]?, name: options[:name]?); nil }, "remove_foreign_key")
    end

    # Reversible when the *to_table* is given; other options are those of
    # `add_foreign_key` (`column:`, `name:`, `on_delete:` ...).
    def remove_foreign_key(from_table : TableName, to_table : TableName, if_exists : Bool = false, **options) : Nil
      record("remove_foreign_key",
        ->(s : SchemaStatements) { s.remove_foreign_key(from_table, to_table, column: options[:column]?, name: options[:name]?, if_exists: if_exists); nil },
        ->(s : SchemaStatements) { s.add_foreign_key(from_table, to_table, **options); nil }, "add_foreign_key")
    end

    def remove_foreign_key(from_table : TableName, column : ColumnNames? = nil, name : ::String | Symbol? = nil, if_exists : Bool = false) : Nil
      record("remove_foreign_key", ->(s : SchemaStatements) { s.remove_foreign_key(from_table, column: column, name: name, if_exists: if_exists); nil })
    end

    def add_check_constraint(table : TableName, expression : ::String, **options) : Nil
      record("add_check_constraint",
        ->(s : SchemaStatements) { s.add_check_constraint(table, expression, **options); nil },
        ->(s : SchemaStatements) { s.remove_check_constraint(table, expression, name: options[:name]?); nil }, "remove_check_constraint")
    end

    def remove_check_constraint(table : TableName, expression : ::String, **options) : Nil
      record("remove_check_constraint",
        ->(s : SchemaStatements) { s.remove_check_constraint(table, expression, name: options[:name]?); nil },
        ->(s : SchemaStatements) { s.add_check_constraint(table, expression, **options); nil }, "add_check_constraint")
    end

    def add_unique_constraint(table : TableName, columns : ColumnNames, **options) : Nil
      record("add_unique_constraint",
        ->(s : SchemaStatements) { s.add_unique_constraint(table, columns, **options); nil },
        ->(s : SchemaStatements) { s.remove_unique_constraint(table, columns, name: options[:name]?); nil }, "remove_unique_constraint")
    end

    def remove_unique_constraint(table : TableName, columns : ColumnNames, **options) : Nil
      record("remove_unique_constraint",
        ->(s : SchemaStatements) { s.remove_unique_constraint(table, columns, name: options[:name]?); nil },
        ->(s : SchemaStatements) { s.add_unique_constraint(table, columns, **options); nil }, "add_unique_constraint")
    end

    # ---- PostgreSQL ------------------------------------------------------

    def enable_extension(name : ::String | Symbol) : Nil
      record("enable_extension",
        ->(s : SchemaStatements) { s.enable_extension(name); nil },
        ->(s : SchemaStatements) { s.disable_extension(name); nil }, "disable_extension")
    end

    def disable_extension(name : ::String | Symbol, cascade : Bool = true) : Nil
      record("disable_extension",
        ->(s : SchemaStatements) { s.disable_extension(name, cascade: cascade); nil },
        ->(s : SchemaStatements) { s.enable_extension(name); nil }, "enable_extension")
    end

    def create_enum(name : ::String | Symbol, values : Array(::String) | Array(Symbol), if_not_exists : Bool = false) : Nil
      record("create_enum",
        ->(s : SchemaStatements) { s.create_enum(name, values, if_not_exists: if_not_exists); nil },
        ->(s : SchemaStatements) { s.drop_enum(name, if_exists: if_not_exists); nil }, "drop_enum")
    end

    def drop_enum(name : ::String | Symbol, values : Array(::String) | Array(Symbol), if_exists : Bool = false, cascade : Bool = false) : Nil
      record("drop_enum",
        ->(s : SchemaStatements) { s.drop_enum(name, if_exists: if_exists, cascade: cascade); nil },
        ->(s : SchemaStatements) { s.create_enum(name, values); nil }, "create_enum")
    end

    def rename_enum(name : ::String | Symbol, to : ::String | Symbol) : Nil
      record("rename_enum",
        ->(s : SchemaStatements) { s.rename_enum(name, to: to); nil },
        ->(s : SchemaStatements) { s.rename_enum(to, to: name); nil }, "rename_enum")
    end

    def rename_enum_value(name : ::String | Symbol, from : ::String | Symbol, to : ::String | Symbol) : Nil
      record("rename_enum_value",
        ->(s : SchemaStatements) { s.rename_enum_value(name, from: from, to: to); nil },
        ->(s : SchemaStatements) { s.rename_enum_value(name, from: to, to: from); nil }, "rename_enum_value")
    end

    # ---- no inverse ------------------------------------------------------

    {% for name in %w[validate_foreign_key validate_check_constraint add_exclusion_constraint remove_exclusion_constraint
                     remove_columns change_column change_table_comment change_column_comment add_enum_value] %}
      # Recorded without an inverse: reversing a migration that calls it raises
      # `IrreversibleMigration`. Wrap it in `reversible` to give both directions.
      def {{name.id}}(*args, **options) : Nil
        record({{name}}, ->(s : SchemaStatements) { s.{{name.id}}(*args, **options); nil })
      end
    {% end %}

    def change_table(table : TableName, bulk : Bool = false, &block : AlterTableDefinition ->) : Nil
      record("change_table", ->(s : SchemaStatements) { s.change_table(table, bulk) { |t| block.call(t) }; nil })
    end

    def execute(sql : ::String) : Nil
      record("execute", ->(s : SchemaStatements) { s.execute(sql); nil })
    end
  end
end
