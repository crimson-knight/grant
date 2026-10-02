require "./table_rebuild"
require "./table_definition_constraints"

module Grant::Schema
  # One change to a table, in the forms each dialect needs. PostgreSQL and
  # MySQL combine the `clauses` of several steps into one `ALTER TABLE`;
  # SQLite runs `native` statements, or applies the `edit` of every step in a
  # single table rebuild when any step `rebuild?`.
  class AlterStep
    # Statements that must run before the ALTER (a backfill).
    getter pre = [] of ::String
    # `ALTER TABLE` actions PostgreSQL and MySQL can combine.
    getter clauses = [] of ::String
    # Statements that run after the ALTER (indexes, comments, renames).
    getter post = [] of ::String
    # What SQLite runs when no rebuild is needed.
    getter native = [] of ::String
    property edit : Proc(TableRebuild, Nil)? = nil
    property? rebuild : Bool = false
  end

  # The block argument of `change_table`: collects changes to one table and
  # lets the statements object turn them into SQL.
  #
  # ```
  # statements.change_table(:users, bulk: true) do |t|
  #   t.string :nickname
  #   t.remove :legacy_flag
  #   t.change_null :email, false, default: ""
  #   t.index :nickname, unique: true
  # end
  # ```
  class AlterTableDefinition
    getter table : ::String
    getter steps = [] of AlterStep

    def initialize(@table : ::String, @source : AlterStatements)
    end

    # Adds a column of *type*.
    def column(name : ::String | Symbol, type : ColumnKind | Symbol | ::String, null : Bool = true,
               default : DefaultLiteral | Unset = UNSET, default_sql : ::String? = nil, limit : Int32? = nil,
               precision : Int32? = nil, scale : Int32? = nil, comment : ::String? = nil,
               collation : ::String? = nil, array : Bool = false, if_not_exists : Bool = false) : Nil
      definition = TableDefinition.new(@table).column(name, type, null, default, default_sql, limit, precision, scale,
        comment, collation, array)
      @steps << @source.step_add_column(@table, definition, if_not_exists)
    end

    {% for method, kind in {string: "String", text: "Text", integer: "Integer", smallint: "SmallInt", tinyint: "TinyInt",
                            bigint: "BigInt", boolean: "Boolean", float: "Float", double: "Double", decimal: "Decimal",
                            datetime: "DateTime", timestamp: "Timestamp", time: "Time", date: "Date", binary: "Binary",
                            json: "Json", jsonb: "Jsonb", uuid: "Uuid"} %}
      # Adds one or more `{{kind.id}}` columns.
      def {{method.id}}(*names : ::String | Symbol, null : Bool = true, default : DefaultLiteral | Unset = UNSET,
                        default_sql : ::String? = nil, limit : Int32? = nil, precision : Int32? = nil,
                        scale : Int32? = nil, comment : ::String? = nil, collation : ::String? = nil,
                        array : Bool = false, if_not_exists : Bool = false) : Nil
        names.each do |name|
          column(name, ColumnKind::{{kind.id}}, null, default, default_sql, limit, precision, scale, comment,
            collation, array, if_not_exists)
        end
      end
    {% end %}

    # Adds `created_at` and `updated_at`.
    def timestamps(null : Bool = false, precision : Int32? = 6, default : DefaultLiteral | Unset = UNSET,
                   default_sql : ::String? = nil) : Nil
      {"created_at", "updated_at"}.each do |name|
        column(name, ColumnKind::DateTime, null, default, default_sql, nil, precision)
      end
    end

    # Drops *names*.
    def remove(*names : ::String | Symbol, if_exists : Bool = false) : Nil
      names.each { |name| @steps << @source.step_remove_column(@table, name.to_s, if_exists) }
    end

    # Changes the type (and optionally null and default) of *name*.
    def change(name : ::String | Symbol, type : ColumnKind | Symbol | ::String, null : Bool? = nil,
               default : DefaultLiteral | Unset = UNSET, default_sql : ::String? = nil, limit : Int32? = nil,
               precision : Int32? = nil, scale : Int32? = nil, collation : ::String? = nil, using : ::String? = nil) : Nil
      @steps << @source.step_change_column(@table, name.to_s, type, null, default, default_sql, limit, precision, scale, collation, using)
    end

    def change_null(name : ::String | Symbol, null : Bool, default : DefaultLiteral | Unset = UNSET) : Nil
      @steps << @source.step_change_column_null(@table, name.to_s, null, default)
    end

    def change_default(name : ::String | Symbol, to : DefaultLiteral | Unset = UNSET, default_sql : ::String? = nil) : Nil
      @steps << @source.step_change_column_default(@table, name.to_s, to, default_sql)
    end

    def rename(old : ::String | Symbol, new : ::String | Symbol) : Nil
      @steps << @source.step_rename_column(@table, old.to_s, new.to_s)
    end

    def index(columns : ColumnNames, name : ::String | Symbol? = nil, unique : Bool = false, where : ::String? = nil,
              using : ::String | Symbol? = nil, order = nil,
              opclass = nil,
              include covering : ColumnNames? = nil, length = nil,
              algorithm : Symbol? = nil, if_not_exists : Bool = false) : Nil
      definition = IndexDefinition.build(@table, columns, name, unique, where, using, order, opclass, covering, length, algorithm, if_not_exists)
      @steps << @source.step_statements(definition.statements(@source.dialect))
    end

    def remove_index(columns : ColumnNames? = nil, name : ::String | Symbol? = nil, if_exists : Bool = false) : Nil
      @steps << @source.step_statements(@source.remove_index_statements(@table, columns, name, if_exists))
    end

    def rename_index(old : ::String | Symbol, new : ::String | Symbol) : Nil
      @steps << @source.step_statements(@source.rename_index_statements(@table, old, new))
    end

    def foreign_key(to_table : TableName, column : ColumnNames? = nil, primary_key : ColumnNames? = nil,
                    name : ::String | Symbol? = nil, on_delete : Symbol? = nil, on_update : Symbol? = nil,
                    deferrable : Bool | Symbol? = nil, validate : Bool = true) : Nil
      definition = ForeignKeyDefinition.build(@table, to_table, column, primary_key, name, on_delete, on_update, deferrable, validate)
      @steps << @source.step_add_foreign_key(definition)
    end

    def remove_foreign_key(to_table : TableName? = nil, column : ColumnNames? = nil, name : ::String | Symbol? = nil) : Nil
      @steps << @source.step_remove_foreign_key(@table, to_table, column, name, false)
    end

    def check_constraint(expression : ::String, name : ::String | Symbol? = nil, validate : Bool = true) : Nil
      @steps << @source.step_add_check(CheckConstraintDefinition.new(@table, expression, name.try(&.to_s), validate))
    end

    def remove_check_constraint(expression : ::String? = nil, name : ::String | Symbol? = nil) : Nil
      @steps << @source.step_remove_check(@table, expression, name.try(&.to_s))
    end

    def unique_constraint(columns : ColumnNames, name : ::String | Symbol? = nil, deferrable : Bool | Symbol? = nil) : Nil
      @steps << @source.step_add_unique(UniqueConstraintDefinition.new(@table, IndexDefinition.to_names(columns), name.try(&.to_s), deferrable))
    end

    def remove_unique_constraint(columns : ColumnNames? = nil, name : ::String | Symbol? = nil) : Nil
      @steps << @source.step_remove_unique(@table, columns, name.try(&.to_s))
    end

    def references(*names : ::String | Symbol, polymorphic : Bool = false, null : Bool = true, index : Bool = true,
                   foreign_key : Bool | NamedTuple = false, type : Symbol = :bigint, default : DefaultLiteral | Unset = UNSET,
                   comment : ::String? = nil, unique : Bool = false) : Nil
      definition = TableDefinition.new(@table)
      definition.references(*names, polymorphic: polymorphic, null: null, index: index, foreign_key: foreign_key,
        type: type, default: default, comment: comment, unique: unique)
      @source.steps_for_reference(definition).each { |step| @steps << step }
    end

    def remove_references(*names : ::String | Symbol, polymorphic : Bool = false, foreign_key : Bool = false) : Nil
      names.each do |name|
        @source.steps_remove_reference(@table, name.to_s, polymorphic, foreign_key).each { |step| @steps << step }
      end
    end

    # Sets the table comment (PostgreSQL, MySQL).
    def comment(text : ::String?) : Nil
      @steps << @source.step_statements(@source.change_table_comment_statements(@table, text))
    end

    # Sets the comment of column *name* (PostgreSQL, MySQL).
    def column_comment(name : ::String | Symbol, text : ::String?) : Nil
      @steps << @source.step_statements(@source.change_column_comment_statements(@table, name, text))
    end
  end

  # ALTER TABLE operations, included by `SchemaStatements`.
  #
  # Lock and rewrite costs, per operation:
  #
  # * `add_column` with a constant default and `change_column_null` on
  #   PostgreSQL 11+ are metadata-only; `SET NOT NULL` scans the table unless a
  #   validated `CHECK (col IS NOT NULL)` exists (PostgreSQL 12+). On MySQL and
  #   on SQLite a `change_column` rewrites the table.
  # * `add_index` blocks writes; `algorithm: :concurrently` (PostgreSQL) does
  #   not, but cannot run in a transaction.
  # * `add_foreign_key` and `add_check_constraint` scan the table under a lock
  #   on PostgreSQL; `validate: false` adds them `NOT VALID` (cheap) and
  #   `validate_foreign_key` / `validate_check_constraint` validate later with
  #   a weaker lock.
  # * SQLite cannot add or drop those constraints, or change a column, in
  #   place: Grant rebuilds the table (`TableRebuild`), copying every row.
  # * `bulk: true` in `change_table` combines the actions into one `ALTER
  #   TABLE` (one scan or rewrite instead of one per action) on PostgreSQL and
  #   MySQL, and into one rebuild on SQLite.
  # * Renames are metadata-only but take an exclusive lock.
  module AlterStatements
    abstract def dialect : Dialect
    abstract def execute(sql : ::String) : Nil

    # Runs *statements* in order. A runner that owns a connection overrides
    # this to run them on one connection (SQLite's table rebuild needs that).
    def execute_batch(statements : Array(::String)) : Nil
      statements.each { |sql| execute sql }
    end

    # The `CREATE TABLE` text of *table* and the `CREATE INDEX` text of its
    # indexes, read from `sqlite_master`. Needed to rebuild a SQLite table.
    def catalog_sqlite_table(table : ::String) : {::String, Array(::String)}
      raise UnsupportedOperation.new("Rebuilding '#{table}' on SQLite needs its definition; use AdapterStatements or RecordingStatements#sqlite_tables")
    end

    # What the database already has, for guards such as `if_not_exists:` and for
    # names that depend on it. A runner without a database answers nil
    # (unknown), and the statements are then emitted unguarded.
    def lookup_column(table : ::String, column : ::String) : ColumnInfo?
      nil
    end

    def lookup_indexes(table : ::String) : Array(IndexInfo)?
      nil
    end

    def lookup_foreign_keys(table : ::String) : Array(ForeignKeyInfo)?
      nil
    end

    def lookup_primary_key(table : ::String) : Array(::String)?
      nil
    end

    # True/false when the column's presence is known, nil when it is not.
    def column_present?(table : ::String, column : ::String) : Bool?
      nil
    end

    # ---- indexes -------------------------------------------------------

    # Returns the SQL that creates an index on *columns* of *table*.
    #
    # * `unique`, `name` (default `index_<table>_on_<columns>`), `where`
    #   (partial; not MySQL), `using` (PostgreSQL method; MySQL `fulltext`,
    #   `spatial`, `btree`, `hash`), `order` (`{email: :desc}` or `:desc`),
    #   `opclass` (PostgreSQL), `include` (PostgreSQL), `length` (MySQL prefix).
    # * A column that is not a plain name is an expression (`"lower(email)"`);
    #   the index then needs a `name`.
    # * `algorithm: :concurrently` (PostgreSQL; ignored elsewhere). Such an
    #   index cannot be built inside a transaction: see
    #   `AdapterStatements#transaction`.
    # * `if_not_exists` (PostgreSQL, SQLite).
    def add_index_statements(table : TableName, columns : ColumnNames, name : ::String | Symbol? = nil, unique : Bool = false,
                             where : ::String? = nil, using : ::String | Symbol? = nil,
                             order = nil,
                             opclass = nil,
                             include covering : ColumnNames? = nil, length = nil,
                             algorithm : Symbol? = nil, if_not_exists : Bool = false, comment : ::String? = nil) : Array(::String)
      IndexDefinition.build(table, columns, name, unique, where, using, order, opclass, covering, length, algorithm, if_not_exists, comment)
        .statements(dialect)
    end

    # Returns the SQL that drops an index by *name*, or the default name of
    # *columns*.
    def remove_index_statements(table : TableName, columns : ColumnNames? = nil, name : ::String | Symbol? = nil,
                                if_exists : Bool = false, algorithm : Symbol? = nil) : Array(::String)
      index_name = name.try(&.to_s)
      if index_name.nil?
        raise InvalidDefinition.new("remove_index on '#{table}' needs columns: or name:") unless columns
        index_name = Naming.index_name(table, IndexDefinition.to_names(columns))
      end
      if if_exists && !dialect.pg? && !dialect.sqlite?
        if (known = lookup_indexes(table.to_s)) && known.none? { |index| index.name == index_name }
          return [] of ::String
        end
      end
      dialect = self.dialect
      case dialect
      in .pg?
        concurrently = algorithm == :concurrently ? "CONCURRENTLY " : ""
        ["DROP INDEX #{concurrently}#{if_exists ? "IF EXISTS " : ""}#{dialect.quote(Naming.in_schema_of(table, index_name))}"]
      in .mysql?
        ["DROP INDEX #{dialect.quote(index_name)} ON #{dialect.quote(table.to_s)}"]
      in .sqlite?
        ["DROP INDEX #{if_exists ? "IF EXISTS " : ""}#{dialect.quote(Naming.in_schema_of(table, index_name))}"]
      end
    end

    # Returns the SQL that renames index *old* to *new*. SQLite has no
    # `ALTER INDEX`: the index is dropped and created again, which needs a
    # runner that can read the existing index.
    def rename_index_statements(table : TableName, old : ::String | Symbol, new : ::String | Symbol) : Array(::String)
      dialect = self.dialect
      case dialect
      in .pg?
        ["ALTER INDEX #{dialect.quote(Naming.in_schema_of(table, old))} RENAME TO #{dialect.quote(new.to_s)}"]
      in .mysql?
        ["ALTER TABLE #{dialect.quote(table.to_s)} RENAME INDEX #{dialect.quote(old.to_s)} TO #{dialect.quote(new.to_s)}"]
      in .sqlite?
        info = lookup_indexes(table.to_s).try(&.find { |index| index.name == old.to_s })
        raise UnsupportedOperation.new("Renaming index '#{old}' on SQLite needs a database connection to read it") unless info
        recreate_index_statements(info, info.columns, new.to_s)
      end
    end

    # ---- foreign keys --------------------------------------------------

    # Returns the SQL that adds a foreign key from *from_table* to *to_table*.
    #
    # * `column` defaults to `<singular to_table>_id`, `primary_key` to `id`,
    #   `name` to `fk_<table>_<column>`.
    # * `on_delete` / `on_update`: `:cascade`, `:restrict`, `:nullify`,
    #   `:set_default`, `:no_action`.
    # * `deferrable`: `true`, `:immediate` or `:deferred` (PostgreSQL).
    # * `validate: false` (PostgreSQL) adds it `NOT VALID`: existing rows are
    #   not scanned; run `validate_foreign_key` afterwards.
    # * SQLite rebuilds the table.
    def add_foreign_key_statements(from_table : TableName, to_table : TableName, column : ColumnNames? = nil,
                                   primary_key : ColumnNames? = nil, name : ::String | Symbol? = nil,
                                   on_delete : Symbol? = nil, on_update : Symbol? = nil,
                                   deferrable : Bool | Symbol? = nil, validate : Bool = true,
                                   if_not_exists : Bool = false) : Array(::String)
      definition = ForeignKeyDefinition.build(from_table, to_table, column, primary_key, name, on_delete, on_update, deferrable, validate)
      if if_not_exists && (known = lookup_foreign_keys(definition.table))
        return [] of ::String if known.any? { |key| key.to_table == definition.to_table && key.columns == definition.columns }
      end
      render_steps(definition.table, [step_add_foreign_key(definition)], false)
    end

    # Returns the SQL that validates a foreign key added with `validate: false`
    # (PostgreSQL; nothing elsewhere).
    def validate_foreign_key_statements(from_table : TableName, to_table : TableName? = nil, column : ColumnNames? = nil,
                                        name : ::String | Symbol? = nil) : Array(::String)
      return [] of ::String unless dialect.pg?
      key_name = name.try(&.to_s) || resolve_foreign_key_name(from_table.to_s, to_table, column)
      ["ALTER TABLE #{dialect.quote(from_table.to_s)} VALIDATE CONSTRAINT #{dialect.quote(key_name)}"]
    end

    # Returns the SQL that drops a foreign key, found by *name*, or by
    # *column* / *to_table*.
    def remove_foreign_key_statements(from_table : TableName, to_table : TableName? = nil, column : ColumnNames? = nil,
                                      name : ::String | Symbol? = nil, if_exists : Bool = false) : Array(::String)
      if if_exists && (known = lookup_foreign_keys(from_table.to_s))
        wanted = column ? IndexDefinition.to_names(column) : (to_table ? [Naming.foreign_key_column(to_table)] : nil)
        found = known.any? do |key|
          (name && key.name == name.to_s) || (wanted && key.columns == wanted && (to_table.nil? || key.to_table == to_table.to_s))
        end
        return [] of ::String unless found
      end
      render_steps(from_table.to_s, [step_remove_foreign_key(from_table.to_s, to_table, column, name, if_exists)], false)
    end

    # ---- check, unique and exclusion constraints -----------------------

    # Returns the SQL that adds `CHECK (expression)` (MySQL 8.0.16+). The
    # default name is `chk_<table>_<digest of the expression>`. `validate:
    # false` (PostgreSQL) adds it `NOT VALID`; see `validate_check_constraint`.
    def add_check_constraint_statements(table : TableName, expression : ::String, name : ::String | Symbol? = nil,
                                        validate : Bool = true) : Array(::String)
      definition = CheckConstraintDefinition.new(table.to_s, expression, name.try(&.to_s), validate)
      render_steps(table.to_s, [step_add_check(definition)], false)
    end

    def remove_check_constraint_statements(table : TableName, expression : ::String? = nil,
                                           name : ::String | Symbol? = nil) : Array(::String)
      render_steps(table.to_s, [step_remove_check(table.to_s, expression, name.try(&.to_s))], false)
    end

    # PostgreSQL only; nothing elsewhere.
    def validate_check_constraint_statements(table : TableName, expression : ::String? = nil,
                                             name : ::String | Symbol? = nil) : Array(::String)
      return [] of ::String unless dialect.pg?
      key_name = check_constraint_name(table.to_s, expression, name.try(&.to_s))
      ["ALTER TABLE #{dialect.quote(table.to_s)} VALIDATE CONSTRAINT #{dialect.quote(key_name)}"]
    end

    # Returns the SQL that adds `UNIQUE (columns)` as a named constraint.
    # `using_index` (PostgreSQL) promotes an index built `concurrently`
    # without a second scan; `deferrable` is PostgreSQL only.
    def add_unique_constraint_statements(table : TableName, columns : ColumnNames, name : ::String | Symbol? = nil,
                                         deferrable : Bool | Symbol? = nil, using_index : ::String | Symbol? = nil) : Array(::String)
      definition = UniqueConstraintDefinition.new(table.to_s, IndexDefinition.to_names(columns), name.try(&.to_s), deferrable, using_index.try(&.to_s))
      render_steps(table.to_s, [step_add_unique(definition)], false)
    end

    def remove_unique_constraint_statements(table : TableName, columns : ColumnNames? = nil,
                                            name : ::String | Symbol? = nil) : Array(::String)
      render_steps(table.to_s, [step_remove_unique(table.to_s, columns, name.try(&.to_s))], false)
    end

    # Returns the SQL that adds an exclusion constraint (PostgreSQL only).
    def add_exclusion_constraint_statements(table : TableName, expression : ::String, using : ::String | Symbol? = nil,
                                            where : ::String? = nil, name : ::String | Symbol? = nil,
                                            deferrable : Bool | Symbol? = nil) : Array(::String)
      definition = ExclusionConstraintDefinition.new(table.to_s, expression, using.try(&.to_s), where, name.try(&.to_s), deferrable)
      ["ALTER TABLE #{dialect.quote(table.to_s)} ADD #{definition.constraint_sql(dialect)}"]
    end

    def remove_exclusion_constraint_statements(table : TableName, expression : ::String? = nil,
                                               name : ::String | Symbol? = nil) : Array(::String)
      raise UnsupportedOperation.new("Exclusion constraints are only supported on PostgreSQL") unless dialect.pg?
      key_name = name.try(&.to_s) || (expression ? Naming.constraint_name("excl", table, Naming.digest(expression)) : raise InvalidDefinition.new("remove_exclusion_constraint needs expression: or name:"))
      ["ALTER TABLE #{dialect.quote(table.to_s)} DROP CONSTRAINT #{dialect.quote(key_name)}"]
    end

    # ---- columns -------------------------------------------------------

    # Returns the SQL that adds a column. See `TableDefinition#column` for the
    # options; `if_not_exists` is native on PostgreSQL and a lookup elsewhere.
    # On SQLite a column with an expression default or a primary key rebuilds
    # the table, and `null: false` needs a constant `default:`.
    def add_column_statements(table : TableName, name : ::String | Symbol, type : ColumnKind | Symbol | ::String,
                              null : Bool = true, default : DefaultLiteral | Unset = UNSET, default_sql : ::String? = nil,
                              limit : Int32? = nil, precision : Int32? = nil, scale : Int32? = nil,
                              comment : ::String? = nil, collation : ::String? = nil, array : Bool = false,
                              primary_key : Bool = false, if_not_exists : Bool = false) : Array(::String)
      definition = TableDefinition.new(table.to_s).column(name, type, null, default, default_sql, limit, precision, scale,
        comment, collation, array, primary_key)
      render_steps(table.to_s, [step_add_column(table.to_s, definition, if_not_exists)], false)
    end

    # Returns the SQL that drops *name*. SQLite rebuilds the table.
    def remove_column_statements(table : TableName, name : ::String | Symbol, type : ColumnKind | Symbol | ::String? = nil,
                                 if_exists : Bool = false) : Array(::String)
      render_steps(table.to_s, [step_remove_column(table.to_s, name.to_s, if_exists)], false)
    end

    # Returns the SQL that drops several columns in one statement.
    def remove_columns_statements(table : TableName, *names : ::String | Symbol, if_exists : Bool = false) : Array(::String)
      render_steps(table.to_s, names.map { |name| step_remove_column(table.to_s, name.to_s, if_exists) }.to_a, true)
    end

    # Returns the SQL that changes *name* to *type*. `null:` and `default:`
    # left out keep the column's own (PostgreSQL, SQLite); `using:` is a
    # PostgreSQL conversion expression. MySQL and SQLite rewrite the table.
    def change_column_statements(table : TableName, name : ::String | Symbol, type : ColumnKind | Symbol | ::String,
                                 null : Bool? = nil, default : DefaultLiteral | Unset = UNSET, default_sql : ::String? = nil,
                                 limit : Int32? = nil, precision : Int32? = nil, scale : Int32? = nil,
                                 collation : ::String? = nil, using : ::String? = nil) : Array(::String)
      render_steps(table.to_s, [step_change_column(table.to_s, name.to_s, type, null, default, default_sql, limit, precision, scale, collation, using)], false)
    end

    # Returns the SQL that allows or forbids NULL in *column*. With `null:
    # false` and a *default*, existing NULLs are first set to it.
    def change_column_null_statements(table : TableName, column : ::String | Symbol, null : Bool,
                                      default : DefaultLiteral | Unset = UNSET) : Array(::String)
      render_steps(table.to_s, [step_change_column_null(table.to_s, column.to_s, null, default)], false)
    end

    # Returns the SQL that renames a column. Indexes that carry the default
    # name of the old column are renamed to match.
    def rename_column_statements(table : TableName, old : ::String | Symbol, new : ::String | Symbol) : Array(::String)
      render_steps(table.to_s, [step_rename_column(table.to_s, old.to_s, new.to_s)], false)
    end

    # Returns the SQL that renames a table. On PostgreSQL the primary key
    # sequence (`<table>_<pk>_seq`) and index (`<table>_pkey`) follow, and on
    # every dialect the indexes that carry the default name.
    def rename_table_statements(old : TableName, new : TableName) : Array(::String)
      dialect = self.dialect
      old_name = old.to_s
      new_name = new.to_s
      # PostgreSQL and SQLite rename within the schema: the new name is bare.
      bare_new = new_name.rpartition('.').last
      result = case dialect
               in .mysql?        then ["RENAME TABLE #{dialect.quote(old_name)} TO #{dialect.quote(new_name)}"]
               in .pg?, .sqlite? then ["ALTER TABLE #{dialect.quote(old_name)} RENAME TO #{dialect.quote(bare_new)}"]
               end
      if dialect.pg?
        keys = lookup_primary_key(old_name) || ["id"]
        old_bare = old_name.rpartition('.').last
        if keys.size == 1
          result << "ALTER SEQUENCE IF EXISTS #{dialect.quote(Naming.in_schema_of(old_name, "#{old_bare}_#{keys.first}_seq"))} RENAME TO #{dialect.quote("#{bare_new}_#{keys.first}_seq")}"
        end
        result << "ALTER INDEX IF EXISTS #{dialect.quote(Naming.in_schema_of(old_name, "#{old_bare}_pkey"))} RENAME TO #{dialect.quote("#{bare_new}_pkey")}"
      end
      (lookup_indexes(old_name) || [] of IndexInfo).each do |index|
        next unless index.name == Naming.index_name(old_name, index.columns)
        target = Naming.index_name(new_name, index.columns)
        if dialect.sqlite?
          result.concat recreate_index_statements(index, index.columns, target, new_name)
        else
          result.concat rename_index_statements(new_name, index.name, target)
        end
      end
      result
    end

    # ---- join tables, references, comments ------------------------------

    # Returns the SQL that creates the join table of *first* and *second*:
    # no primary key, a `<singular>_id` column for each (`null: false`
    # unless `column_options: {null: true}`), named `<a>_<b>` alphabetically.
    # The block can add more columns or `t.index`.
    def create_join_table_statements(first : TableName, second : TableName, table_name : TableName? = nil,
                                     column_options : NamedTuple = NamedTuple.new, &) : Array(::String)
      name = table_name.try(&.to_s) || Naming.join_table_name(first, second)
      null = column_options[:null]? == true
      type = column_options[:type]? || :bigint
      create_table_statements(name, id: false) do |t|
        t.column(Naming.foreign_key_column(first), type, null)
        t.column(Naming.foreign_key_column(second), type, null)
        yield t
      end
    end

    def create_join_table_statements(first : TableName, second : TableName, table_name : TableName? = nil,
                                     column_options : NamedTuple = NamedTuple.new) : Array(::String)
      create_join_table_statements(first, second, table_name, column_options) { }
    end

    def drop_join_table_statements(first : TableName, second : TableName, table_name : TableName? = nil,
                                   if_exists : Bool = false) : Array(::String)
      drop_table_statements(table_name || Naming.join_table_name(first, second), if_exists: if_exists)
    end

    # Returns the SQL that adds the column(s), index and foreign key of a
    # reference; see `TableDefinition#references`. On SQLite the foreign key
    # is written on the column (which must then be nullable).
    def add_reference_statements(table : TableName, *names : ::String | Symbol, polymorphic : Bool = false, null : Bool = true,
                                 index : Bool = true, foreign_key : Bool | NamedTuple = false, type : Symbol = :bigint,
                                 default : DefaultLiteral | Unset = UNSET, comment : ::String? = nil,
                                 unique : Bool = false) : Array(::String)
      definition = TableDefinition.new(table.to_s)
      definition.references(*names, polymorphic: polymorphic, null: null, index: index, foreign_key: foreign_key,
        type: type, default: default, comment: comment, unique: unique)
      render_steps(table.to_s, steps_for_reference(definition), false)
    end

    # Returns the SQL that drops a reference's column(s) and, on MySQL, its
    # foreign key first.
    def remove_reference_statements(table : TableName, *names : ::String | Symbol, polymorphic : Bool = false,
                                    foreign_key : Bool = false) : Array(::String)
      steps = names.flat_map { |name| steps_remove_reference(table.to_s, name.to_s, polymorphic, foreign_key) }.to_a
      render_steps(table.to_s, steps, false)
    end

    # Sets the table comment: `COMMENT ON TABLE` on PostgreSQL, `COMMENT=` on
    # MySQL, nothing on SQLite. `nil` removes it.
    def change_table_comment_statements(table : TableName, text : ::String?) : Array(::String)
      dialect = self.dialect
      case dialect
      in .pg?
        ["COMMENT ON TABLE #{dialect.quote(table.to_s)} IS #{text ? dialect.quote_literal(text) : "NULL"}"]
      in .mysql?
        ["ALTER TABLE #{dialect.quote(table.to_s)} COMMENT = #{dialect.quote_literal(text || "")}"]
      in .sqlite?
        [] of ::String
      end
    end

    # Sets the comment of a column. MySQL restates the column, which needs a
    # runner that can read it.
    def change_column_comment_statements(table : TableName, column : ::String | Symbol, text : ::String?) : Array(::String)
      dialect = self.dialect
      case dialect
      in .pg?
        ["COMMENT ON COLUMN #{dialect.quote(table.to_s)}.#{dialect.quote(column.to_s)} IS #{text ? dialect.quote_literal(text) : "NULL"}"]
      in .mysql?
        info = lookup_column(table.to_s, column.to_s) || raise UnsupportedOperation.new("Changing the comment of '#{table}.#{column}' on MySQL needs a database connection to read the column")
        ["ALTER TABLE #{dialect.quote(table.to_s)} MODIFY COLUMN #{mysql_column_sql(info, null: info.null?, comment: text || "")}"]
      in .sqlite?
        [] of ::String
      end
    end

    # ---- PostgreSQL enums and extensions -------------------------------

    # Returns the SQL that creates the enum type *name* (PostgreSQL).
    def create_enum_statements(name : ::String | Symbol, values : Array(::String) | Array(Symbol), if_not_exists : Bool = false) : Array(::String)
      require_pg!("create_enum")
      raise InvalidDefinition.new("Enum '#{name}' needs at least one value") if values.empty?
      list = values.map { |value| dialect.quote_literal(value.to_s) }.join(", ")
      create = "CREATE TYPE #{dialect.quote(name.to_s)} AS ENUM (#{list})"
      return [create] unless if_not_exists
      ["DO $grant$ BEGIN #{create}; EXCEPTION WHEN duplicate_object THEN NULL; END $grant$"]
    end

    def drop_enum_statements(name : ::String | Symbol, if_exists : Bool = false, cascade : Bool = false) : Array(::String)
      require_pg!("drop_enum")
      ["DROP TYPE #{if_exists ? "IF EXISTS " : ""}#{dialect.quote(name.to_s)}#{cascade ? " CASCADE" : ""}"]
    end

    def rename_enum_statements(name : ::String | Symbol, to : ::String | Symbol) : Array(::String)
      require_pg!("rename_enum")
      ["ALTER TYPE #{dialect.quote(name.to_s)} RENAME TO #{dialect.quote(to.to_s)}"]
    end

    # Adds a value to an enum. Before PostgreSQL 12 `ALTER TYPE ... ADD VALUE`
    # cannot run in a transaction, and a new value cannot be used until the
    # transaction that added it commits.
    def add_enum_value_statements(name : ::String | Symbol, value : ::String | Symbol, before : ::String | Symbol? = nil,
                                  after : ::String | Symbol? = nil, if_not_exists : Bool = false) : Array(::String)
      require_pg!("add_enum_value")
      raise InvalidDefinition.new("Give before: or after:, not both") if before && after
      sql = "ALTER TYPE #{dialect.quote(name.to_s)} ADD VALUE #{if_not_exists ? "IF NOT EXISTS " : ""}#{dialect.quote_literal(value.to_s)}"
      sql += " BEFORE #{dialect.quote_literal(before.to_s)}" if before
      sql += " AFTER #{dialect.quote_literal(after.to_s)}" if after
      [sql]
    end

    def rename_enum_value_statements(name : ::String | Symbol, from : ::String | Symbol, to : ::String | Symbol) : Array(::String)
      require_pg!("rename_enum_value")
      ["ALTER TYPE #{dialect.quote(name.to_s)} RENAME VALUE #{dialect.quote_literal(from.to_s)} TO #{dialect.quote_literal(to.to_s)}"]
    end

    # `CREATE EXTENSION IF NOT EXISTS` on PostgreSQL; nothing elsewhere, so a
    # migration that enables `pgcrypto` still runs on SQLite.
    def enable_extension_statements(name : ::String | Symbol) : Array(::String)
      return [] of ::String unless dialect.pg?
      ["CREATE EXTENSION IF NOT EXISTS #{dialect.quote(name.to_s)}"]
    end

    def disable_extension_statements(name : ::String | Symbol, cascade : Bool = true) : Array(::String)
      return [] of ::String unless dialect.pg?
      ["DROP EXTENSION IF EXISTS #{dialect.quote(name.to_s)}#{cascade ? " CASCADE" : ""}"]
    end

    # ---- change_table ---------------------------------------------------

    # Returns the SQL of the changes made in the block (see
    # `AlterTableDefinition`). With `bulk: true` the actions are combined
    # into as few `ALTER TABLE` statements as the dialect allows.
    def change_table_statements(table : TableName, bulk : Bool = false, &) : Array(::String)
      definition = AlterTableDefinition.new(table.to_s, self)
      yield definition
      render_steps(table.to_s, definition.steps, bulk)
    end

    # ---- executing forms -------------------------------------------------

    {% for name in %w[add_index remove_index rename_index add_foreign_key validate_foreign_key remove_foreign_key
                     add_check_constraint remove_check_constraint validate_check_constraint add_unique_constraint
                     remove_unique_constraint add_exclusion_constraint remove_exclusion_constraint add_column
                     remove_column remove_columns change_column change_column_null rename_column rename_table
                     add_reference remove_reference change_table_comment change_column_comment create_enum
                     drop_enum rename_enum add_enum_value rename_enum_value enable_extension disable_extension
                     drop_join_table] %}
      # Runs the statements of `#{{name.id}}_statements`.
      def {{name.id}}(*args, **options) : Nil
        execute_batch({{name.id}}_statements(*args, **options))
      end
    {% end %}

    # Creates the join table of `#create_join_table_statements`.
    def create_join_table(first : TableName, second : TableName, table_name : TableName? = nil,
                          column_options : NamedTuple = NamedTuple.new, &) : Nil
      execute_batch(create_join_table_statements(first, second, table_name, column_options) { |t| yield t })
    end

    def create_join_table(first : TableName, second : TableName, table_name : TableName? = nil,
                          column_options : NamedTuple = NamedTuple.new) : Nil
      execute_batch(create_join_table_statements(first, second, table_name, column_options))
    end

    # Runs the changes of `#change_table_statements`.
    def change_table(table : TableName, bulk : Bool = false, &) : Nil
      execute_batch(change_table_statements(table, bulk) { |t| yield t })
    end

    # ---- steps (used by AlterTableDefinition) ---------------------------

    # :nodoc:
    def step_statements(statements : Array(::String)) : AlterStep
      step = AlterStep.new
      step.post.concat statements
      step
    end

    # :nodoc:
    def step_add_column(table : ::String, definition : ColumnDefinition, if_not_exists : Bool = false, inline_reference : ForeignKeyDefinition? = nil) : AlterStep
      dialect = self.dialect
      step = AlterStep.new
      return step if if_not_exists && !dialect.pg? && column_present?(table, definition.name) == true
      column_sql = definition.to_sql(dialect)
      case dialect
      in .pg?
        step.clauses << "ADD COLUMN #{if_not_exists ? "IF NOT EXISTS " : ""}#{column_sql}"
        if text = definition.comment
          step.post << "COMMENT ON COLUMN #{dialect.quote(table)}.#{dialect.quote(definition.name)} IS #{dialect.quote_literal(text)}"
        end
      in .mysql?
        step.clauses << "ADD COLUMN #{column_sql}"
      in .sqlite?
        # SQLite refuses ADD COLUMN ... NOT NULL without a default, so that
        # case rebuilds the table (it succeeds while the table is empty).
        needs_rebuild = !definition.null && definition.default.is_a?(Unset) && definition.default_sql.nil? && !definition.primary_key?
        column_sql += " PRIMARY KEY" if definition.primary_key?
        column_sql += " #{inline_reference.inline_sql(dialect)}" if inline_reference
        step.native << "ALTER TABLE #{dialect.quote(table)} ADD COLUMN #{column_sql}"
        step.rebuild = needs_rebuild || definition.primary_key? || !definition.default_sql.nil?
        step.edit = ->(rebuild : TableRebuild) { rebuild.add_column(column_sql) }
      end
      step
    end

    # :nodoc:
    def step_remove_column(table : ::String, name : ::String, if_exists : Bool = false) : AlterStep
      dialect = self.dialect
      step = AlterStep.new
      return step if if_exists && !dialect.pg? && column_present?(table, name) == false
      case dialect
      in .pg?
        step.clauses << "DROP COLUMN #{if_exists ? "IF EXISTS " : ""}#{dialect.quote(name)}"
      in .mysql?
        step.clauses << "DROP COLUMN #{dialect.quote(name)}"
      in .sqlite?
        step.rebuild = true
        step.edit = ->(rebuild : TableRebuild) { rebuild.remove_column(name) }
      end
      step
    end

    # :nodoc:
    def step_change_column(table : ::String, name : ::String, type : ColumnKind | Symbol | ::String, null : Bool?,
                           default : DefaultLiteral | Unset, default_sql : ::String?, limit : Int32?, precision : Int32?,
                           scale : Int32?, collation : ::String?, using : ::String?) : AlterStep
      dialect = self.dialect
      definition = TableDefinition.new(table).column(name, type, null != false, default, default_sql, limit, precision, scale, nil, collation)
      step = AlterStep.new
      case dialect
      in .pg?
        action = "ALTER COLUMN #{dialect.quote(name)} TYPE #{definition.sql_type(dialect)}"
        action += " COLLATE #{dialect.quote(collation)}" if collation
        action += " USING #{using}" if using
        step.clauses << action
        step.clauses << "ALTER COLUMN #{dialect.quote(name)} #{null ? "DROP" : "SET"} NOT NULL" unless null.nil?
        if clause = definition.default_clause(dialect)
          step.clauses << "ALTER COLUMN #{dialect.quote(name)} SET #{clause}"
        end
      in .mysql?
        current = lookup_column(table, name)
        nullable = null.nil? ? (current ? current.null? : true) : null
        definition.null = nullable
        # MODIFY restates the whole column, so a default the caller did not
        # name would be lost; carry the current one over (it is SQL text).
        kept = current.try(&.default) if definition.default.is_a?(Unset) && definition.default_sql.nil?
        step.clauses << "MODIFY COLUMN #{definition.to_sql(dialect)}#{" DEFAULT #{mysql_default_text(kept)}" if kept}"
      in .sqlite?
        step.rebuild = true
        step.edit = ->(rebuild : TableRebuild) do
          rebuild.change_column(name) do |old|
            definition.null = true
            text = definition.to_sql(dialect)
            keep_not_null = null.nil? ? old.matches?(/\sNOT\s+NULL\b/i) : !null
            text += " NOT NULL" if keep_not_null
            if definition.default.is_a?(Unset) && definition.default_sql.nil?
              previous = TableRebuild::Scanner.default_clause(old)
              text += " #{previous}" if previous
            end
            if key = old[/\sPRIMARY\s+KEY(?:\s+(?:ASC|DESC))?(?:\s+AUTOINCREMENT)?/i]?
              text += key
            end
            text
          end
        end
      end
      step
    end

    # :nodoc:
    def step_change_column_default(table : ::String, name : ::String, to : DefaultLiteral | Unset, default_sql : ::String?) : AlterStep
      step = AlterStep.new
      dialect = self.dialect
      unless dialect.sqlite?
        change_column_default_sql(table, name, to, default_sql).each { |sql| step.post << sql }
        return step
      end
      raise InvalidDefinition.new("change_column_default needs to: or default_sql:") if default_sql.nil? && to.is_a?(Unset)
      step.rebuild = true
      step.edit = ->(rebuild : TableRebuild) do
        rebuild.change_column(name) do |old|
          text = old
          if previous = TableRebuild::Scanner.default_clause(old)
            text = old.sub(previous, "")
          end
          if expression = default_sql
            "#{text} DEFAULT #{dialect.default_expression(expression)}"
          elsif to.nil?
            text
          elsif to.is_a?(Unset)
            text
          else
            "#{text} DEFAULT #{dialect.quote_literal(to)}"
          end
        end
      end
      step
    end

    # :nodoc:
    def step_change_column_null(table : ::String, column : ::String, null : Bool, default : DefaultLiteral | Unset) : AlterStep
      dialect = self.dialect
      step = AlterStep.new
      if !null && !default.is_a?(Unset)
        step.pre << "UPDATE #{dialect.quote(table)} SET #{dialect.quote(column)} = #{dialect.quote_literal(default)} WHERE #{dialect.quote(column)} IS NULL"
      end
      case dialect
      in .pg?
        step.clauses << "ALTER COLUMN #{dialect.quote(column)} #{null ? "DROP" : "SET"} NOT NULL"
      in .mysql?
        info = lookup_column(table, column) || raise UnsupportedOperation.new("Changing NULL of '#{table}.#{column}' on MySQL needs a database connection to read the column")
        step.clauses << "MODIFY COLUMN #{mysql_column_sql(info, null: null)}"
      in .sqlite?
        step.rebuild = true
        step.edit = ->(rebuild : TableRebuild) do
          rebuild.change_column(column) do |old|
            text = old.gsub(/\s+NOT\s+NULL\b/i, "")
            null ? text : "#{text} NOT NULL"
          end
        end
      end
      step
    end

    # :nodoc:
    def step_rename_column(table : ::String, old : ::String, new : ::String) : AlterStep
      dialect = self.dialect
      step = AlterStep.new
      statements = ["ALTER TABLE #{dialect.quote(table)} RENAME COLUMN #{dialect.quote(old)} TO #{dialect.quote(new)}"]
      (lookup_indexes(table) || [] of IndexInfo).each do |index|
        next unless index.name == Naming.index_name(table, index.columns) && index.columns.includes?(old)
        columns = index.columns.map { |column| column == old ? new : column }
        target = Naming.index_name(table, columns)
        if dialect.sqlite?
          statements.concat recreate_index_statements(index, columns, target)
        else
          statements.concat rename_index_statements(table, index.name, target)
        end
      end
      if dialect.sqlite?
        step.native.concat statements
      else
        step.post.concat statements
      end
      step
    end

    # :nodoc:
    def step_add_foreign_key(definition : ForeignKeyDefinition) : AlterStep
      dialect = self.dialect
      step = AlterStep.new
      case dialect
      in .pg?
        step.clauses << "ADD #{definition.constraint_sql(dialect)}#{definition.validate? ? "" : " NOT VALID"}"
      in .mysql?
        step.clauses << "ADD #{definition.constraint_sql(dialect)}"
      in .sqlite?
        step.rebuild = true
        sql = definition.constraint_sql(dialect)
        step.edit = ->(rebuild : TableRebuild) { rebuild.add_constraint(sql) }
      end
      step
    end

    # :nodoc:
    def step_remove_foreign_key(table : ::String, to_table : TableName?, column : ColumnNames?, name : ::String | Symbol?, if_exists : Bool) : AlterStep
      dialect = self.dialect
      step = AlterStep.new
      columns = column ? IndexDefinition.to_names(column) : (to_table ? [Naming.foreign_key_column(to_table)] : nil)
      if dialect.sqlite?
        wanted_name = name.try(&.to_s)
        raise InvalidDefinition.new("remove_foreign_key on '#{table}' needs to_table:, column: or name:") if columns.nil? && wanted_name.nil?
        step.rebuild = true
        step.edit = ->(rebuild : TableRebuild) do
          removed = rebuild.remove_foreign_key(wanted_name, columns)
          raise InvalidDefinition.new("Table '#{table}' has no such foreign key") if removed == 0 && !if_exists
        end
        return step
      end
      key_name = name.try(&.to_s) || resolve_foreign_key_name(table, to_table, column)
      if dialect.pg?
        step.clauses << "DROP CONSTRAINT #{if_exists ? "IF EXISTS " : ""}#{dialect.quote(key_name)}"
      else
        step.clauses << "DROP FOREIGN KEY #{dialect.quote(key_name)}"
      end
      step
    end

    # :nodoc:
    def step_add_check(definition : CheckConstraintDefinition) : AlterStep
      dialect = self.dialect
      step = AlterStep.new
      if dialect.sqlite?
        step.rebuild = true
        sql = definition.constraint_sql(dialect)
        step.edit = ->(rebuild : TableRebuild) { rebuild.add_constraint(sql) }
      else
        step.clauses << "ADD #{definition.constraint_sql(dialect)}#{dialect.pg? && !definition.validate? ? " NOT VALID" : ""}"
      end
      step
    end

    # :nodoc:
    def step_remove_check(table : ::String, expression : ::String?, name : ::String?) : AlterStep
      dialect = self.dialect
      step = AlterStep.new
      raise InvalidDefinition.new("remove_check_constraint on '#{table}' needs expression: or name:") if expression.nil? && name.nil?
      if dialect.sqlite?
        step.rebuild = true
        step.edit = ->(rebuild : TableRebuild) do
          removed = rebuild.remove_check(name, expression)
          raise InvalidDefinition.new("Table '#{table}' has no such check constraint") if removed == 0
        end
      else
        key_name = check_constraint_name(table, expression, name)
        step.clauses << (dialect.pg? ? "DROP CONSTRAINT #{dialect.quote(key_name)}" : "DROP CHECK #{dialect.quote(key_name)}")
      end
      step
    end

    # :nodoc:
    def step_add_unique(definition : UniqueConstraintDefinition) : AlterStep
      dialect = self.dialect
      step = AlterStep.new
      if dialect.sqlite?
        step.rebuild = true
        sql = definition.constraint_sql(dialect)
        step.edit = ->(rebuild : TableRebuild) { rebuild.add_constraint(sql) }
      else
        step.clauses << "ADD #{definition.constraint_sql(dialect)}"
      end
      step
    end

    # :nodoc:
    def step_remove_unique(table : ::String, columns : ColumnNames?, name : ::String?) : AlterStep
      dialect = self.dialect
      step = AlterStep.new
      names = columns ? IndexDefinition.to_names(columns) : nil
      key_name = name
      if key_name.nil?
        raise InvalidDefinition.new("remove_unique_constraint on '#{table}' needs columns: or name:") unless names
        key_name = Naming.constraint_name("uniq", table, names.join("_"))
      end
      case dialect
      in .sqlite?
        step.rebuild = true
        step.edit = ->(rebuild : TableRebuild) do
          removed = rebuild.remove_unique(key_name, names)
          raise InvalidDefinition.new("Table '#{table}' has no such unique constraint") if removed == 0
        end
      in .pg?
        step.clauses << "DROP CONSTRAINT #{dialect.quote(key_name)}"
      in .mysql?
        step.clauses << "DROP INDEX #{dialect.quote(key_name)}"
      end
      step
    end

    # :nodoc:
    def steps_for_reference(definition : TableDefinition) : Array(AlterStep)
      dialect = self.dialect
      steps = [] of AlterStep
      inline = definition.foreign_keys.to_h { |key| {key.columns.first, key} }
      definition.columns.each do |column|
        reference = dialect.sqlite? ? inline[column.name]? : nil
        steps << step_add_column(definition.name, column, false, reference)
      end
      definition.indexes.each { |index| steps << step_statements(index.statements(dialect)) }
      unless dialect.sqlite?
        definition.foreign_keys.each { |key| steps << step_add_foreign_key(key) }
      end
      steps
    end

    # :nodoc:
    def steps_remove_reference(table : ::String, name : ::String, polymorphic : Bool, foreign_key : Bool) : Array(AlterStep)
      steps = [] of AlterStep
      column = "#{name}_id"
      if foreign_key && dialect.mysql?
        steps << step_remove_foreign_key(table, nil, column, nil, false)
      end
      steps << step_remove_column(table, column, false)
      steps << step_remove_column(table, "#{name}_type", false) if polymorphic
      steps
    end

    # Turns *steps* into SQL for the dialect; see `AlterStep`.
    #
    # :nodoc:
    def render_steps(table : ::String, steps : Array(AlterStep), bulk : Bool) : Array(::String)
      dialect = self.dialect
      result = [] of ::String
      if dialect.sqlite?
        if steps.any?(&.rebuild?)
          steps.each { |step| result.concat step.pre }
          create_sql, index_sqls = catalog_sqlite_table(table)
          rebuild = TableRebuild.new(table, create_sql, index_sqls)
          steps.each do |step|
            if edit = step.edit
              edit.call(rebuild)
            elsif !step.native.empty?
              raise UnsupportedOperation.new("This change to '#{table}' cannot be combined with a table rebuild on SQLite; run it separately")
            end
          end
          result.concat rebuild.statements
          steps.each { |step| result.concat step.post }
        else
          steps.each do |step|
            result.concat step.pre
            result.concat step.native
            result.concat step.post
          end
        end
        return result
      end

      head = "ALTER TABLE #{dialect.quote(table)}"
      pending = [] of ::String
      flush = -> do
        unless pending.empty?
          result << "#{head} #{pending.join(", ")}"
          pending.clear
        end
      end
      steps.each do |step|
        unless step.pre.empty?
          flush.call
          result.concat step.pre
        end
        pending.concat step.clauses
        flush.call unless bulk
        unless step.post.empty?
          flush.call
          result.concat step.post
        end
      end
      flush.call
      result
    end

    # ---- helpers ---------------------------------------------------------

    private def recreate_index_statements(info : IndexInfo, columns : Array(::String), name : ::String, table : ::String = info.table_name) : Array(::String)
      definition = IndexDefinition.new(table, columns, name, info.unique?, info.where)
      ["DROP INDEX #{dialect.quote(Naming.in_schema_of(table, info.name))}", definition.to_sql(dialect)]
    end

    private def resolve_foreign_key_name(table : ::String, to_table : TableName?, column : ColumnNames?) : ::String
      columns = column ? IndexDefinition.to_names(column) : (to_table ? [Naming.foreign_key_column(to_table)] : nil)
      raise InvalidDefinition.new("A foreign key of '#{table}' needs to_table:, column: or name:") unless columns
      if known = lookup_foreign_keys(table)
        if found = known.find { |key| key.columns == columns && (to_table.nil? || key.to_table == to_table.to_s) }
          return found.name || Naming.constraint_name("fk", table, columns.join("_"))
        end
      end
      Naming.constraint_name("fk", table, columns.join("_"))
    end

    private def check_constraint_name(table : ::String, expression : ::String?, name : ::String?) : ::String
      name || (expression ? Naming.constraint_name("chk", table, Naming.digest(expression)) : raise InvalidDefinition.new("A check constraint of '#{table}' needs expression: or name:"))
    end

    private def require_pg!(operation : ::String) : Nil
      raise UnsupportedOperation.new("#{operation} is only supported on PostgreSQL") unless dialect.pg?
    end

    # A catalog default (`ColumnInfo#default`) as a MySQL `DEFAULT` operand: a
    # literal as it is, anything else as an expression.
    private def mysql_default_text(text : ::String) : ::String
      text.matches?(/\A(?:'(?:[^']|'')*'|-?\d+(?:\.\d+)?|NULL|TRUE|FALSE)\z/i) ? text : dialect.default_expression(text)
    end

    # MySQL restates a whole column to change one property of it.
    private def mysql_column_sql(info : ColumnInfo, null : Bool, comment : ::String? = nil) : ::String
      String.build do |io|
        io << dialect.quote(info.name) << ' ' << info.sql_type
        io << " NOT NULL" unless null
        if value = info.default
          io << " DEFAULT " << mysql_default_text(value)
        end
        io << " AUTO_INCREMENT" if info.auto_increment?
        text = comment || info.comment
        io << " COMMENT " << dialect.quote_literal(text) if text && !text.empty?
      end
    end
  end
end
