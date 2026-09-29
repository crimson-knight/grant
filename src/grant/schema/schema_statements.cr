require "./table_definition"

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
      if default_sql.nil? && to.is_a?(Unset)
        raise InvalidDefinition.new("change_column_default needs to: or default_sql:")
      end
      head = "ALTER TABLE #{dialect.quote(table.to_s)} ALTER COLUMN #{dialect.quote(column.to_s)}"
      if expression = default_sql
        ["#{head} SET DEFAULT #{dialect.default_expression(expression)}"]
      elsif to.nil?
        ["#{head} DROP DEFAULT"]
      else
        ["#{head} SET DEFAULT #{dialect.quote_literal(to.as(DefaultLiteral))}"]
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
             in Array then primary_key.map(&.to_s)
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

    def execute(sql : ::String) : Nil
      @adapter.open(sql) { |db| db.exec sql }
      @adapter.reset_schema_caches!
    end
  end

  # Records the SQL instead of running it: a recording mock for asserting the
  # statements of a dialect without its database.
  class RecordingStatements
    include SchemaStatements

    getter dialect : Dialect
    getter statements = [] of ::String

    def initialize(@dialect : Dialect)
    end

    def execute(sql : ::String) : Nil
      @statements << sql
    end
  end
end
