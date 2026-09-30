require "./table_definition"
require "./alter_table"

module Grant::Schema
  alias TableName = ::String | Symbol
  alias ColumnNames = ::String | Symbol | Array(::String) | Array(Symbol)

  # Schema-changing statements: `create_table`, `drop_table`, `add_timestamps`,
  # `remove_timestamps`, `change_column_default`.
  #
  # Every operation exists twice. `*_statements` returns the SQL as an array of
  # strings and never touches a database, so the SQL of any dialect can be
  # asserted; the plain name runs those statements through `#execute`.
  # Include the module and define `#dialect` and `#execute`, or use
  # `AdapterStatements` (a real connection) or `RecordingStatements` (a
  # recording mock).
  #
  # ```
  # statements = Grant::Schema::AdapterStatements.new(User.adapter)
  # statements.create_table(:memberships, id: false, primary_key: [:user_id, :group_id]) do |t|
  #   t.bigint :user_id
  #   t.bigint :group_id
  #   t.timestamps
  # end
  # ```
  #
  # Cost notes: these are DDL statements and take no per-row work. Changing a
  # column default is metadata-only on PostgreSQL and on MySQL 8+; older MySQL
  # can rewrite the table. `add_timestamps` with a constant default is
  # metadata-only on PostgreSQL 11+ and can rewrite the table on MySQL.
  module SchemaStatements
    include AlterStatements

    abstract def dialect : Dialect
    abstract def execute(sql : ::String) : Nil

    # Returns the SQL that creates *name*.
    #
    # * `id`: `true`/`:bigint` (default), `:integer`, `:smallint`, `:uuid`,
    #   `:string`, or `false` for no primary key column.
    # * `primary_key`: the auto column's name (`"id"` by default), or an array
    #   of columns declared in the block for a composite primary key. Columns
    #   declared with `primary_key: true` do the same.
    # * `force`: drop the table first; `:cascade` also cascades (PostgreSQL).
    # * `comment`: a table comment (PostgreSQL, MySQL; SQLite has none).
    # * `options`: raw text appended after the closing parenthesis.
    #
    # The block can also declare `t.index`, `t.references`, `t.foreign_key`,
    # `t.check_constraint`, `t.unique_constraint` and `t.exclusion_constraint`.
    # Constraints are part of the `CREATE TABLE`; indexes follow it.
    def create_table_statements(name : TableName, id : Bool | Symbol = true, primary_key : ColumnNames? = nil,
                                if_not_exists : Bool = false, temporary : Bool = false,
                                force : Bool | Symbol = false, comment : ::String? = nil,
                                options : ::String? = nil, &) : Array(::String)
      table = TableDefinition.new(name.to_s)
      yield table
      dialect = self.dialect

      keys = primary_key_columns(table, primary_key)
      auto_id = id != false && keys.empty?
      key_name = "id"
      if primary_key.is_a?(::String) || primary_key.is_a?(Symbol)
        key_name = primary_key.to_s
      end
      lines = [] of ::String
      lines << auto_id_sql(dialect, key_name, id.is_a?(Symbol) ? id : :bigint) if auto_id
      composite = keys.size > 1
      table.columns.each do |column|
        column.null = false if composite && keys.includes?(column.name)
        line = column.to_sql(dialect)
        line += " PRIMARY KEY" if keys.size == 1 && keys.first == column.name
        lines << line
      end
      lines << "PRIMARY KEY (#{keys.map { |key| dialect.quote(key) }.join(", ")})" if composite
      table.unique_constraints.each { |constraint| lines << constraint.constraint_sql(dialect) }
      table.check_constraints.each { |constraint| lines << constraint.constraint_sql(dialect) }
      table.exclusion_constraints.each { |constraint| lines << constraint.constraint_sql(dialect) }
      table.foreign_keys.each { |key| lines << key.constraint_sql(dialect) }

      statements = [] of ::String
      if force
        statements << drop_table_sql(dialect, name.to_s, true, force == :cascade)
      end
      sql = String.build do |io|
        io << "CREATE "
        io << "TEMPORARY " if temporary
        io << "TABLE "
        io << "IF NOT EXISTS " if if_not_exists
        io << dialect.quote(name.to_s) << " (\n  " << lines.join(",\n  ") << "\n)"
        io << " COMMENT=" << dialect.quote_literal(comment) if comment && dialect.mysql?
        io << ' ' << options if options
      end
      statements << sql
      if dialect.pg?
        if text = comment
          statements << "COMMENT ON TABLE #{dialect.quote(name.to_s)} IS #{dialect.quote_literal(text)}"
        end
        table.columns.each do |column|
          if text = column.comment
            statements << "COMMENT ON COLUMN #{dialect.quote(name.to_s)}.#{dialect.quote(column.name)} IS #{dialect.quote_literal(text)}"
          end
        end
      end
      table.indexes.each { |index| statements.concat index.statements(dialect) }
      statements
    end

    # Creates *name*; see `#create_table_statements` for the options.
    def create_table(name : TableName, id : Bool | Symbol = true, primary_key : ColumnNames? = nil,
                     if_not_exists : Bool = false, temporary : Bool = false,
                     force : Bool | Symbol = false, comment : ::String? = nil,
                     options : ::String? = nil, &) : Nil
      create_table_statements(name, id, primary_key, if_not_exists, temporary, force, comment, options) { |table| yield table }
        .each { |sql| execute sql }
    end

    # Returns the SQL that drops each of *names*, one statement per table.
    # `cascade` is honored on PostgreSQL only.
    def drop_table_statements(*names : TableName, if_exists : Bool = false, cascade : Bool = false) : Array(::String)
      names.map { |name| drop_table_sql(dialect, name.to_s, if_exists, cascade) }.to_a
    end

    def drop_table(*names : TableName, if_exists : Bool = false, cascade : Bool = false) : Nil
      drop_table_statements(*names, if_exists: if_exists, cascade: cascade).each { |sql| execute sql }
    end

    # Returns the SQL that adds `created_at` and `updated_at` to *table*.
    #
    # SQLite cannot add a `NOT NULL` column without a default, so
    # `null: false` there needs `default:`; pass `null: true` or rebuild the
    # table instead.
    def add_timestamps_statements(table : TableName, null : Bool = false, precision : Int32? = 6,
                                  default : DefaultLiteral | Unset = UNSET, default_sql : ::String? = nil) : Array(::String)
      dialect = self.dialect
      if dialect.sqlite? && !null && default.is_a?(Unset) && default_sql.nil?
        raise UnsupportedOperation.new("SQLite cannot add NOT NULL timestamps to '#{table}' without a default; pass null: true or a default:")
      end
      definition = TableDefinition.new(table.to_s)
      definition.timestamps(null, precision, default, default_sql)
      adds = definition.columns.map { |column| "ADD COLUMN #{column.to_sql(dialect)}" }
      alter_each(dialect, table.to_s, adds)
    end

    def add_timestamps(table : TableName, null : Bool = false, precision : Int32? = 6,
                       default : DefaultLiteral | Unset = UNSET, default_sql : ::String? = nil) : Nil
      add_timestamps_statements(table, null, precision, default, default_sql).each { |sql| execute sql }
    end

    # Returns the SQL that drops `created_at` and `updated_at` from *table*.
    def remove_timestamps_statements(table : TableName) : Array(::String)
      dialect = self.dialect
      drops = {"created_at", "updated_at"}.map { |column| "DROP COLUMN #{dialect.quote(column)}" }.to_a
      alter_each(dialect, table.to_s, drops)
    end

    def remove_timestamps(table : TableName) : Nil
      remove_timestamps_statements(table).each { |sql| execute sql }
    end

    # Returns the SQL that sets the default of *column* to *to*, or to the SQL
    # expression *default_sql*. `to: nil` drops the default. *from* is the
    # previous default; it is accepted so a caller can record the inverse.
    #
    # SQLite has no `ALTER COLUMN` and raises `UnsupportedOperation`.
    def change_column_default_statements(table : TableName, column : ::String | Symbol,
                                         to : DefaultLiteral | Unset = UNSET, default_sql : ::String? = nil,
                                         from : DefaultLiteral | Unset = UNSET) : Array(::String)
      dialect = self.dialect
      if dialect.sqlite?
        raise UnsupportedOperation.new("SQLite cannot change the default of '#{table}.#{column}' in place; it needs a table rebuild")
      end
      head = "ALTER TABLE #{dialect.quote(table.to_s)} ALTER COLUMN #{dialect.quote(column.to_s)}"
      if expression = default_sql
        ["#{head} SET DEFAULT #{dialect.default_expression(expression)}"]
      elsif to.is_a?(Unset)
        raise InvalidDefinition.new("change_column_default needs to: or default_sql:")
      elsif to.nil?
        ["#{head} DROP DEFAULT"]
      else
        ["#{head} SET DEFAULT #{dialect.quote_literal(to)}"]
      end
    end

    def change_column_default(table : TableName, column : ::String | Symbol,
                              to : DefaultLiteral | Unset = UNSET, default_sql : ::String? = nil,
                              from : DefaultLiteral | Unset = UNSET) : Nil
      change_column_default_statements(table, column, to, default_sql, from).each { |sql| execute sql }
    end

    private def drop_table_sql(dialect : Dialect, name : ::String, if_exists : Bool, cascade : Bool) : ::String
      String.build do |io|
        io << "DROP TABLE "
        io << "IF EXISTS " if if_exists
        io << dialect.quote(name)
        io << " CASCADE" if cascade && dialect.pg?
      end
    end

    # PostgreSQL and MySQL take several actions in one ALTER; SQLite takes one
    # per statement.
    private def alter_each(dialect : Dialect, table : ::String, actions : Array(::String)) : Array(::String)
      head = "ALTER TABLE #{dialect.quote(table)}"
      if dialect.sqlite?
        actions.map { |action| "#{head} #{action}" }
      else
        ["#{head} #{actions.join(", ")}"]
      end
    end

    private def primary_key_columns(table : TableDefinition, primary_key : ColumnNames?) : Array(::String)
      keys = case primary_key
             in Array                 then primary_key.map(&.to_s)
             in ::String, Symbol, Nil then [] of ::String
             end
      flagged = table.columns.select(&.primary_key?).map(&.name)
      raise InvalidDefinition.new("Give the primary key as primary_key: or per column, not both") if !keys.empty? && !flagged.empty?
      keys = flagged if keys.empty?
      keys.each do |key|
        unless table.columns.any? { |column| column.name == key }
          raise InvalidDefinition.new("Primary key column '#{key}' is not defined in '#{table.name}'")
        end
      end
      keys
    end

    private def auto_id_sql(dialect : Dialect, name : ::String, kind : Symbol) : ::String
      quoted = dialect.quote(name)
      case kind
      when :bigint, :integer, :smallint
        case dialect
        in .pg?
          serial = {bigint: "BIGSERIAL", integer: "SERIAL", smallint: "SMALLSERIAL"}[kind]
          "#{quoted} #{serial} PRIMARY KEY"
        in .mysql?
          int = {bigint: "BIGINT", integer: "INT", smallint: "SMALLINT"}[kind]
          "#{quoted} #{int} NOT NULL AUTO_INCREMENT PRIMARY KEY"
        in .sqlite?
          "#{quoted} INTEGER PRIMARY KEY AUTOINCREMENT"
        end
      when :uuid
        case dialect
        in .pg?     then "#{quoted} UUID PRIMARY KEY DEFAULT gen_random_uuid()"
        in .mysql?  then "#{quoted} CHAR(36) PRIMARY KEY DEFAULT (UUID())"
        in .sqlite? then "#{quoted} CHAR(36) PRIMARY KEY"
        end
      when :string
        "#{quoted} #{dialect.pg? ? "VARCHAR" : "VARCHAR(255)"} PRIMARY KEY"
      else
        raise InvalidDefinition.new("Unknown id type #{kind.inspect}; use :bigint, :integer, :smallint, :uuid, :string or false")
      end
    end
  end

  # Runs schema statements on a real adapter, then drops the adapter's cached
  # catalog so introspection sees the change.
  class AdapterStatements
    include SchemaStatements

    getter adapter : Grant::Adapter::Base
    getter dialect : Dialect

    def initialize(@adapter : Grant::Adapter::Base)
      @dialect = Dialect.for(@adapter)
    end

    # True while a `#transaction` block is open.
    getter? in_transaction : Bool = false

    def execute(sql : ::String) : Nil
      execute_batch([sql])
    end

    # Runs *statements* in order on one connection, then drops the cached
    # catalog. A failed SQLite table rebuild is rolled back and its
    # `PRAGMA foreign_keys` restored.
    def execute_batch(statements : Array(::String)) : Nil
      return if statements.empty?
      if @in_transaction && statements.any? { |sql| sql.matches?(/\A\s*CREATE\s+(UNIQUE\s+)?INDEX\s+CONCURRENTLY\b/i) || sql.matches?(/\A\s*DROP\s+INDEX\s+CONCURRENTLY\b/i) }
        raise InvalidDefinition.new("CONCURRENTLY cannot run inside a transaction; use transaction(disable_ddl_transaction: true)")
      end
      if @in_transaction && statements.includes?("BEGIN")
        raise InvalidDefinition.new("A SQLite table rebuild cannot run inside a transaction: it must switch foreign key enforcement off first")
      end
      begin
        @adapter.open(statements.first) do |db|
          begin
            statements.each { |sql| db.exec sql }
          rescue ex
            if dialect.sqlite? && statements.includes?("BEGIN")
              begin
                db.exec "ROLLBACK"
              rescue DB::Error
                # Best effort: the original error is re-raised below.
              end
              begin
                db.exec "PRAGMA foreign_keys = ON"
              rescue DB::Error
                # Best effort: the original error is re-raised below.
              end
            end
            raise ex
          end
        end
      ensure
        @adapter.reset_schema_caches!
      end
    end

    # Runs the block with its statements in one transaction, for databases
    # with transactional DDL (PostgreSQL, SQLite). `disable_ddl_transaction:
    # true` runs them without one, which a `CREATE INDEX CONCURRENTLY`
    # requires. Inside a transaction a concurrent index raises
    # `InvalidDefinition` instead of failing in the database.
    def transaction(disable_ddl_transaction : Bool = false, &)
      if disable_ddl_transaction || dialect.mysql?
        yield self
      else
        Grant::Transaction.run(@adapter, Grant::Transaction::Options.new) do
          @in_transaction = true
          begin
            yield self
          ensure
            @in_transaction = false
          end
        end
      end
    end

    def catalog_sqlite_table(table : ::String) : {::String, Array(::String)}
      create = nil.as(::String?)
      indexes = [] of ::String
      @adapter.open do |db|
        create = db.query_one?("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", table, as: ::String?)
        db.query_each("SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL", table) do |rs|
          indexes << rs.read(::String)
        end
      end
      sql = create || raise InvalidDefinition.new("Table '#{table}' does not exist")
      {sql, indexes}
    end

    def lookup_column(table : ::String, column : ::String) : ColumnInfo?
      return nil unless @adapter.schema.table_exists?(table)
      @adapter.schema.columns(table).find { |info| info.name == column }
    end

    def column_present?(table : ::String, column : ::String) : Bool?
      return false unless @adapter.schema.table_exists?(table)
      @adapter.schema.columns(table).any? { |info| info.name == column }
    end

    def lookup_indexes(table : ::String) : Array(IndexInfo)?
      @adapter.schema.table_exists?(table) ? @adapter.schema.indexes(table) : nil
    end

    def lookup_foreign_keys(table : ::String) : Array(ForeignKeyInfo)?
      @adapter.schema.table_exists?(table) ? @adapter.schema.foreign_keys(table) : nil
    end

    def lookup_primary_key(table : ::String) : Array(::String)?
      @adapter.schema.table_exists?(table) ? @adapter.schema.primary_key(table) : nil
    end
  end

  # Records the SQL instead of running it: a recording mock for asserting the
  # statements of a dialect without its database.
  class RecordingStatements
    include SchemaStatements

    getter dialect : Dialect
    getter statements = [] of ::String
    # The `CREATE TABLE` text and index texts `sqlite_master` would hold, for
    # statements that rebuild a SQLite table: `{"posts" => {create_sql, indexes}}`.
    getter sqlite_tables = {} of ::String => {::String, Array(::String)}
    # Catalog answers for guards and default names; nil keys mean unknown.
    getter known_indexes = {} of ::String => Array(IndexInfo)
    getter known_foreign_keys = {} of ::String => Array(ForeignKeyInfo)
    getter known_columns = {} of ::String => Array(ColumnInfo)
    getter known_primary_keys = {} of ::String => Array(::String)

    def initialize(@dialect : Dialect)
    end

    def catalog_sqlite_table(table : ::String) : {::String, Array(::String)}
      @sqlite_tables[table]? || super
    end

    def lookup_indexes(table : ::String) : Array(IndexInfo)?
      @known_indexes[table]?
    end

    def lookup_foreign_keys(table : ::String) : Array(ForeignKeyInfo)?
      @known_foreign_keys[table]?
    end

    def lookup_primary_key(table : ::String) : Array(::String)?
      @known_primary_keys[table]?
    end

    def lookup_column(table : ::String, column : ::String) : ColumnInfo?
      @known_columns[table]?.try(&.find { |info| info.name == column })
    end

    def column_present?(table : ::String, column : ::String) : Bool?
      @known_columns[table]?.try(&.any? { |info| info.name == column })
    end

    def execute(sql : ::String) : Nil
      @statements << sql
    end
  end
end
