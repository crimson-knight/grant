require "./introspection"
require "./schema_statements"
require "./constraint_catalog"
require "./schema_migration"

module Grant::Schema
  # The file format of a schema dump: a Crystal `Grant::Schema.define` block or
  # the database's own SQL.
  enum SchemaFormat
    Crystal
    Sql

    # The conventional file name in *dir*: `schema.cr` or `structure.sql`, with a
    # `<database>_` prefix for any database but `primary`.
    def file_name(database : ::String = "primary") : ::String
      stem = database == "primary" ? "" : "#{database}_"
      crystal? ? "#{stem}schema.cr" : "#{stem}structure.sql"
    end
  end

  @@format = SchemaFormat::Crystal

  # The format the database tasks dump and load by default (`:crystal`).
  def self.format : SchemaFormat
    @@format
  end

  def self.format=(value : SchemaFormat) : SchemaFormat
    @@format = value
  end

  # Accepts `:crystal` or `:sql`.
  def self.format=(value : Symbol) : SchemaFormat
    parsed = SchemaFormat.parse?(value.to_s) || raise InvalidDefinition.new("Unknown schema format #{value.inspect}; use :crystal or :sql")
    @@format = parsed
  end

  # One table of a dump: a `TableDefinition` (columns, indexes, constraints,
  # foreign keys) plus how its primary key is declared.
  class DumpedTable
    getter name : ::String
    getter definition : TableDefinition
    getter comment : ::String?
    # `id:` of `create_table`: `:bigint`, `:integer`, `:smallint`, `:uuid`, or false.
    getter id : Bool | Symbol
    # `primary_key:` of `create_table`: a custom auto key name or composite columns.
    getter primary_key : (::String | Array(::String))?
    # Foreign keys that cannot be declared with the table because they point
    # at a table created later (cycles); they follow as `add_foreign_key`.
    getter deferred_foreign_keys = [] of ForeignKeyDefinition
    # Names the catalog reported, to leave the default ones out of the text.
    getter explicit_names = Set(::String).new

    def initialize(@name : ::String, @definition : TableDefinition, @comment : ::String? = nil,
                   @id : Bool | Symbol = true, @primary_key : (::String | Array(::String))? = nil)
    end

    # Replays the table on *statements*.
    def create(statements : SchemaStatements) : Nil
      definition = @definition
      statements.create_table(@name, id: @id, primary_key: @primary_key, comment: @comment, force: :cascade) do |t|
        definition.columns.each do |column|
          t.column(column.name, column.type, column.null, column.default, column.default_sql, column.limit,
            column.precision, column.scale, column.comment, column.collation, column.array?, column.primary_key?)
        end
        definition.indexes.each do |index|
          t.index(index.columns, index.name, index.unique?, index.where, index.using, index.order, index.opclass,
            index.covering, index.length, index.comment)
        end
        definition.unique_constraints.each { |unique| t.unique_constraint(unique.columns, unique.name, unique.deferrable) }
        definition.check_constraints.each { |check| t.check_constraint(check.expression, check.name) }
        definition.exclusion_constraints.each do |exclusion|
          t.exclusion_constraint(exclusion.expression, exclusion.using, exclusion.where, exclusion.name, exclusion.deferrable)
        end
        definition.foreign_keys.each do |key|
          t.foreign_key(key.to_table, key.columns, key.primary_key, key.name, key.on_delete, key.on_update, key.deferrable)
        end
      end
    end

    # The tables this one needs to exist first.
    def depends_on : Set(::String)
      targets = @definition.foreign_keys.map(&.to_table).to_set
      targets.delete(@name)
      targets
    end
  end

  # Everything a dump holds, in the order it can be loaded: extensions, enum
  # types, tables (parents before children), then the cyclic foreign keys.
  # `#to_crystal` writes it as a `Grant::Schema.define` file and `#apply`
  # replays it on a database; both read the same fields, so a dump loads back
  # to what it described.
  class SchemaSnapshot
    getter version : Int64
    getter extensions : Array(::String)
    getter enums : Hash(::String, Array(::String))
    getter tables : Array(DumpedTable)

    def initialize(@version : Int64, @extensions : Array(::String), @enums : Hash(::String, Array(::String)),
                   @tables : Array(DumpedTable))
    end

    # Foreign keys left for after every table exists.
    def deferred_foreign_keys : Array(ForeignKeyDefinition)
      @tables.flat_map(&.deferred_foreign_keys)
    end

    # Creates everything on *statements*. Existing tables of the same name are
    # dropped first (`force: :cascade`), as a schema load replaces the schema.
    def apply(statements : SchemaStatements) : Nil
      @extensions.each { |name| statements.enable_extension(name) }
      @enums.each { |name, values| statements.create_enum(name, values, if_not_exists: true) }
      @tables.each(&.create(statements))
      deferred_foreign_keys.each do |key|
        statements.add_foreign_key(key.table, key.to_table, key.columns, key.primary_key, key.name,
          key.on_delete, key.on_update, key.deferrable)
      end
    end

    # The dump as Crystal source.
    def to_crystal(io : IO) : Nil
      CrystalWriter.new(self, io).write
    end

    def to_crystal : ::String
      String.build { |io| to_crystal(io) }
    end
  end

  # Writes a `SchemaSnapshot` as Crystal source.
  # :nodoc:
  class CrystalWriter
    def initialize(@snapshot : SchemaSnapshot, @io : IO)
    end

    def write : Nil
      @io << "# This file is auto-generated from the current state of the database. Instead\n"
      @io << "# of editing this file, please use the migrations feature of Grant to change\n"
      @io << "# the schema, then dump it again.\n"
      @io << "#\n"
      @io << "# Require it from the program that runs the database tasks; Grant::Schema.load\n"
      @io << "# (or Grant::Tasks::Database#schema_load) creates the schema on a fresh database.\n\n"
      @io << "Grant::Schema.define(version: " << @snapshot.version << ") do |schema|\n"
      blank = false
      @snapshot.extensions.each do |name|
        @io << "  schema.enable_extension " << name.inspect << '\n'
        blank = true
      end
      @snapshot.enums.each do |name, values|
        @io << "  schema.create_enum " << name.inspect << ", " << values.inspect << ", if_not_exists: true\n"
        blank = true
      end
      @io << '\n' if blank
      @snapshot.tables.each_with_index do |table, position|
        @io << '\n' unless position == 0
        write_table(table)
      end
      deferred = @snapshot.deferred_foreign_keys
      unless deferred.empty?
        @io << '\n'
        deferred.each do |key|
          @io << "  schema.add_foreign_key " << key.table.inspect << ", " << key.to_table.inspect
          @io << foreign_key_options(key, key.table).join
          @io << '\n'
        end
      end
      @io << "end\n"
    end

    private def write_table(table : DumpedTable) : Nil
      options = [] of ::String
      id = table.id
      options << "id: #{id.inspect}" unless id == true
      case key = table.primary_key
      when ::String        then options << "primary_key: #{key.inspect}"
      when Array(::String) then options << "primary_key: #{key.inspect}"
      end
      options << "comment: #{table.comment.inspect}" if table.comment
      options << "force: :cascade"
      @io << "  schema.create_table " << table.name.inspect
      options.each { |option| @io << ", " << option }
      @io << " do |t|\n"
      definition = table.definition
      definition.columns.each { |column| @io << "    " << column_line(column) << '\n' }
      definition.indexes.each { |index| @io << "    " << index_line(index) << '\n' }
      definition.unique_constraints.each { |unique| @io << "    " << unique_line(table, unique) << '\n' }
      definition.check_constraints.each { |check| @io << "    " << check_line(table, check) << '\n' }
      definition.exclusion_constraints.each { |exclusion| @io << "    " << exclusion_line(table, exclusion) << '\n' }
      definition.foreign_keys.each do |foreign_key|
        @io << "    t.foreign_key " << foreign_key.to_table.inspect << foreign_key_options(foreign_key, table.name).join << '\n'
      end
      @io << "  end\n"
    end

    private def column_line(column : ColumnDefinition) : ::String
      kind = column.type
      options = [] of ::String
      options << "null: false" unless column.null
      options << "limit: #{column.limit}" if column.limit
      options << "precision: #{column.precision}" if column.precision
      options << "scale: #{column.scale}" if column.scale
      options << "default_sql: #{column.default_sql.inspect}" if column.default_sql
      options << "comment: #{column.comment.inspect}" if column.comment
      options << "primary_key: true" if column.primary_key?
      head = if kind.is_a?(ColumnKind)
               "t.#{kind.to_s.downcase} #{column.name.inspect}"
             else
               "t.column #{column.name.inspect}, #{kind.inspect}"
             end
      ([head] + options).join(", ")
    end

    private def index_line(index : IndexDefinition) : ::String
      parts = ["t.index #{index.columns.inspect}"]
      parts << "name: #{index.name.inspect}" unless index.name == Naming.index_name(index.table, index.columns)
      parts << "unique: true" if index.unique?
      parts << "where: #{index.where.inspect}" if index.where
      parts << "using: #{index.using.inspect}" if index.using
      parts << "order: #{index.order.inspect}" unless index.order.empty?
      parts << "opclass: #{index.opclass.inspect}" unless index.opclass.empty?
      parts << "include: #{index.covering.inspect}" unless index.covering.empty?
      parts << "comment: #{index.comment.inspect}" if index.comment
      parts.join(", ")
    end

    private def unique_line(table : DumpedTable, unique : UniqueConstraintDefinition) : ::String
      parts = ["t.unique_constraint #{unique.columns.inspect}"]
      parts << "name: #{unique.name.inspect}" if table.explicit_names.includes?(unique.name)
      parts << "deferrable: #{unique.deferrable.inspect}" if unique.deferrable
      parts.join(", ")
    end

    private def check_line(table : DumpedTable, check : CheckConstraintDefinition) : ::String
      parts = ["t.check_constraint #{check.expression.inspect}"]
      parts << "name: #{check.name.inspect}" if table.explicit_names.includes?(check.name)
      parts.join(", ")
    end

    private def exclusion_line(table : DumpedTable, exclusion : ExclusionConstraintDefinition) : ::String
      parts = ["t.exclusion_constraint #{exclusion.expression.inspect}"]
      parts << "using: #{exclusion.using.inspect}" if exclusion.using
      parts << "where: #{exclusion.where.inspect}" if exclusion.where
      parts << "name: #{exclusion.name.inspect}" if table.explicit_names.includes?(exclusion.name)
      parts << "deferrable: #{exclusion.deferrable.inspect}" if exclusion.deferrable
      parts.join(", ")
    end

    # `, column: ..., name: ...` arguments of a foreign key, minus the defaults.
    private def foreign_key_options(key : ForeignKeyDefinition, table : ::String) : Array(::String)
      parts = [] of ::String
      default = ForeignKeyDefinition.build(table, key.to_table)
      parts << ", column: #{one_or_many(key.columns)}" unless key.columns == default.columns
      parts << ", primary_key: #{one_or_many(key.primary_key)}" unless key.primary_key == default.primary_key
      parts << ", name: #{key.name.inspect}" unless key.name == ForeignKeyDefinition.build(table, key.to_table, key.columns).name
      parts << ", on_delete: #{key.on_delete.inspect}" if key.on_delete
      parts << ", on_update: #{key.on_update.inspect}" if key.on_update
      parts << ", deferrable: #{key.deferrable.inspect}" if key.deferrable
      parts
    end

    private def one_or_many(names : Array(::String)) : ::String
      names.size == 1 ? names.first.inspect : names.inspect
    end
  end

  # What the dumper reads in one go for every table: the catalog facts that
  # `Introspection` only answers per table.
  # :nodoc:
  class CatalogExtras
    record Check, expression : ::String, name : ::String?
    record Unique, columns : Array(::String), name : ::String?, deferrable : Bool | Symbol?
    record Exclusion, definition : ::String, name : ::String
    record IndexText, sql : ::String, comment : ::String?

    getter checks = Hash(::String, Array(Check)).new
    getter uniques = Hash(::String, Array(Unique)).new
    getter exclusions = Hash(::String, Array(Exclusion)).new
    getter table_comments = Hash(::String, ::String).new
    getter index_texts = Hash({::String, ::String}, IndexText).new
    # `{table, index name}` => column => "DESC", for catalogs that report key
    # order per column instead of as `CREATE INDEX` text (MySQL).
    getter index_orders = Hash({::String, ::String}, Hash(::String, ::String)).new
    # `{table, foreign key name}` => `true` or `:deferred`.
    getter deferrable_keys = Hash({::String, ::String}, Bool | Symbol).new

    def initialize(@adapter : Grant::Adapter::Base, @dialect : Dialect, @namespace : ::String?)
    end

    # Runs the batched queries: a fixed handful per dialect, however many
    # tables there are.
    def load : self
      case @dialect
      in .pg?     then load_pg
      in .sqlite? then load_sqlite
      in .mysql?  then load_mysql
      end
      self
    end

    private def query(sql : ::String, args : Array(DB::Any) = [] of DB::Any, & : DB::ResultSet ->) : Nil
      @adapter.open(sql, args) do |db|
        db.query sql, args: args do |rs|
          rs.each { yield rs }
        end
      end
    end

    private def load_pg : Nil
      args = [@namespace.as(DB::Any)]
      scope = "n.nspname = COALESCE($1::text, current_schema())"
      joins = "JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace"

      query(<<-SQL, args) do |rs|
        SELECT t.relname::text, c.conname::text, pg_get_expr(c.conbin, c.conrelid)
        FROM pg_constraint c #{joins}
        WHERE c.contype = 'c' AND #{scope} ORDER BY t.relname, c.conname
        SQL
        table = rs.read(::String)
        name = rs.read(::String)
        expression = rs.read(::String)
        (@checks[table] ||= [] of Check) << Check.new(expression, name)
      end

      query(<<-SQL, args) do |rs|
        SELECT t.relname::text, c.conname::text, c.condeferrable, c.condeferred,
               (SELECT array_agg(a.attname::text ORDER BY k.ord) FROM unnest(c.conkey) WITH ORDINALITY k(attnum, ord)
                JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum)
        FROM pg_constraint c #{joins}
        WHERE c.contype = 'u' AND #{scope} ORDER BY t.relname, c.conname
        SQL
        table = rs.read(::String)
        name = rs.read(::String)
        deferrable = rs.read(Bool)
        deferred = rs.read(Bool)
        columns = rs.read(Array(::String))
        mode = deferrable ? (deferred ? :deferred : true) : nil
        (@uniques[table] ||= [] of Unique) << Unique.new(columns, name, mode)
      end

      query(<<-SQL, args) do |rs|
        SELECT t.relname::text, c.conname::text, pg_get_constraintdef(c.oid)
        FROM pg_constraint c #{joins}
        WHERE c.contype = 'x' AND #{scope} ORDER BY t.relname, c.conname
        SQL
        table = rs.read(::String)
        name = rs.read(::String)
        (@exclusions[table] ||= [] of Exclusion) << Exclusion.new(rs.read(::String), name)
      end

      query(<<-SQL, args) do |rs|
        SELECT t.relname::text, c.conname::text, c.condeferred
        FROM pg_constraint c #{joins}
        WHERE c.contype = 'f' AND c.condeferrable AND #{scope}
        SQL
        table = rs.read(::String)
        name = rs.read(::String)
        @deferrable_keys[{table, name}] = rs.read(Bool) ? :deferred : true
      end

      query(<<-SQL, args) do |rs|
        SELECT c.relname::text, obj_description(c.oid, 'pg_class')
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p') AND #{scope} AND obj_description(c.oid, 'pg_class') IS NOT NULL
        SQL
        table = rs.read(::String)
        @table_comments[table] = rs.read(::String)
      end

      query(<<-SQL, args) do |rs|
        SELECT t.relname::text, i.relname::text, pg_get_indexdef(ix.indexrelid), obj_description(i.oid, 'pg_class')
        FROM pg_index ix JOIN pg_class i ON i.oid = ix.indexrelid JOIN pg_class t ON t.oid = ix.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE #{scope} AND NOT ix.indisprimary
        SQL
        table = rs.read(::String)
        name = rs.read(::String)
        sql = rs.read(::String)
        @index_texts[{table, name}] = IndexText.new(sql, rs.read(::String?))
      end
    end

    # One read of `sqlite_master` holds every table's constraints and every
    # index's text.
    private def load_sqlite : Nil
      query("SELECT type, tbl_name, name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'") do |rs|
        type = rs.read(::String)
        table = rs.read(::String)
        name = rs.read(::String)
        sql = rs.read(::String)
        if type == "index"
          @index_texts[{table, name}] = IndexText.new(sql, nil)
        elsif type == "table"
          read_sqlite_table(table, sql)
        end
      end
    end

    private def read_sqlite_table(table : ::String, sql : ::String) : Nil
      TableRebuild.new(table, sql).items.each do |item|
        case item.kind
        when :check
          (@checks[table] ||= [] of Check) << Check.new(TableRebuild::Scanner.check_expression(item.text).strip, item.name)
        when :unique
          (@uniques[table] ||= [] of Unique) << Unique.new(TableRebuild::Scanner.fk_columns(item.text), item.name, nil)
        end
      end
    end

    private def load_mysql : Nil
      query(<<-SQL) do |rs|
        SELECT CAST(tc.TABLE_NAME AS CHAR), CAST(cc.CONSTRAINT_NAME AS CHAR), CAST(cc.CHECK_CLAUSE AS CHAR)
        FROM information_schema.CHECK_CONSTRAINTS cc
        JOIN information_schema.TABLE_CONSTRAINTS tc ON tc.CONSTRAINT_SCHEMA = cc.CONSTRAINT_SCHEMA AND tc.CONSTRAINT_NAME = cc.CONSTRAINT_NAME
        WHERE tc.TABLE_SCHEMA = DATABASE() AND tc.CONSTRAINT_TYPE = 'CHECK' ORDER BY tc.TABLE_NAME, cc.CONSTRAINT_NAME
        SQL
        table = rs.read(::String)
        name = rs.read(::String)
        (@checks[table] ||= [] of Check) << Check.new(rs.read(::String), name)
      end

      query(<<-SQL) do |rs|
        SELECT CAST(tc.TABLE_NAME AS CHAR), CAST(tc.CONSTRAINT_NAME AS CHAR), CAST(k.COLUMN_NAME AS CHAR)
        FROM information_schema.TABLE_CONSTRAINTS tc
        JOIN information_schema.KEY_COLUMN_USAGE k ON k.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA AND k.CONSTRAINT_NAME = tc.CONSTRAINT_NAME AND k.TABLE_NAME = tc.TABLE_NAME
        WHERE tc.TABLE_SCHEMA = DATABASE() AND tc.CONSTRAINT_TYPE = 'UNIQUE'
        ORDER BY tc.TABLE_NAME, tc.CONSTRAINT_NAME, k.ORDINAL_POSITION
        SQL
        table = rs.read(::String)
        name = rs.read(::String)
        column = rs.read(::String)
        list = (@uniques[table] ||= [] of Unique)
        if (last = list.last?) && last.name == name
          list[-1] = Unique.new(last.columns + [column], name, nil)
        else
          list << Unique.new([column], name, nil)
        end
      end

      # COLLATION is "D" for a descending key part (MySQL 8+).
      query(<<-SQL) do |rs|
        SELECT CAST(TABLE_NAME AS CHAR), CAST(INDEX_NAME AS CHAR), CAST(COLUMN_NAME AS CHAR)
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE() AND COLLATION = 'D' AND COLUMN_NAME IS NOT NULL
        ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
        SQL
        index = {rs.read(::String), rs.read(::String)}
        (@index_orders[index] ||= {} of ::String => ::String)[rs.read(::String)] = "DESC"
      end

      query("SELECT CAST(TABLE_NAME AS CHAR), CAST(TABLE_COMMENT AS CHAR) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_COMMENT <> ''") do |rs|
        table = rs.read(::String)
        @table_comments[table] = rs.read(::String)
      end
    end
  end

  # Reads a database's catalog and turns it into a `SchemaSnapshot`, a
  # Crystal `Grant::Schema.define` file, or a SQL structure file.
  #
  # ```
  # File.open("db/schema.cr", "w") { |io| Grant::Schema::Dumper.dump(User.adapter, io) }
  # ```
  #
  # The catalog is read with a fixed number of queries whatever the table
  # count: the columns, indexes and foreign keys come from the adapter's
  # `Introspection` (one query per kind), and the constraints, comments, index
  # definitions and deferral flags from `CatalogExtras` (one query per kind).
  # Tables are listed parents first; foreign keys that form a cycle follow as
  # `add_foreign_key`.
  #
  # What round-trips: columns (type, null, default, comment), primary keys
  # (auto, custom, composite), indexes (unique, partial, expression, `using`,
  # descending columns, `include`, operator classes, comments on PostgreSQL),
  # foreign keys (actions, deferral), check, unique and exclusion constraints,
  # table comments, PostgreSQL extensions and enum types. Not captured:
  # `NULLS FIRST/LAST` of an index column, column collations, views, triggers,
  # functions and non-enum PostgreSQL types. Use the SQL structure dump
  # (`Dumper.dump_structure`) when those matter.
  class Dumper
    # Bookkeeping tables that belong to the tools, not to the application.
    IGNORED_TABLES = [SchemaMigration::TABLE, SchemaMigration::MICRATE_TABLE, InternalMetadata::TABLE, "grant_seeds"]

    # The comment that separates statements in a SQLite structure file.
    STATEMENT_MARKER = "-- grant:statement"

    getter adapter : Grant::Adapter::Base
    getter dialect : Dialect

    def initialize(@adapter : Grant::Adapter::Base, @ignore_tables : Array(::String | Regex) = [] of (::String | Regex),
                   @tracking : Tracking = Tracking::Grant)
      @dialect = Dialect.for(@adapter)
    end

    # Writes the Crystal dump of *adapter*'s schema to *io*.
    def self.dump(adapter : Grant::Adapter::Base, io : IO, ignore_tables : Array(::String | Regex) = [] of (::String | Regex),
                  tracking : Tracking = Tracking::Grant) : Nil
      new(adapter, ignore_tables, tracking).dump(io)
    end

    def self.dump(adapter : Grant::Adapter::Base, ignore_tables : Array(::String | Regex) = [] of (::String | Regex),
                  tracking : Tracking = Tracking::Grant) : ::String
      String.build { |io| dump(adapter, io, ignore_tables, tracking) }
    end

    # Writes the SQL structure of *adapter*'s database to *io*: SQLite from its
    # own catalog, PostgreSQL through `pg_dump`, MySQL through `mysqldump`
    # (those tools must be on the PATH). The versions in `schema_migrations`
    # follow as one `INSERT`.
    def self.dump_structure(adapter : Grant::Adapter::Base, io : IO, tracking : Tracking = Tracking::Grant) : Nil
      new(adapter, tracking: tracking).dump_structure(io)
    end

    def dump(io : IO) : Nil
      snapshot.to_crystal(io)
    end

    # The dump as data, for `SchemaSnapshot#apply`.
    def snapshot : SchemaSnapshot
      schema = @adapter.schema
      schema.reset!
      # One query per kind of catalog data; the per-table reads below are
      # served from memory.
      schema.load_all!
      names = schema.tables.reject { |name| ignored?(name) }
      version = SchemaMigration.new(@adapter, @tracking).current_version
      extras = CatalogExtras.new(@adapter, @dialect, schema.namespace).load

      built = names.map do |name|
        build_table(name, schema.columns(name), schema.indexes(name), schema.foreign_keys(name), extras)
      end
      ordered = order_tables(built)
      enums = @dialect.pg? ? schema.enums : {} of ::String => Array(::String)
      extensions = @dialect.pg? ? schema.extensions.reject { |name| name == "plpgsql" } : [] of ::String
      SchemaSnapshot.new(version, extensions, enums, ordered)
    end

    def dump_structure(io : IO) : Nil
      case @dialect
      in .sqlite? then dump_sqlite_structure(io)
      in .pg?     then dump_with_tool(io, pg_dump_command)
      in .mysql?  then dump_with_tool(io, mysqldump_command)
      end
      append_versions(io)
    end

    private def ignored?(name : ::String) : Bool
      return true if IGNORED_TABLES.includes?(name)
      @ignore_tables.any? do |pattern|
        pattern.is_a?(Regex) ? pattern.matches?(name) : pattern == name
      end
    end

    private def build_table(name : ::String, infos : Array(ColumnInfo), indexes : Array(IndexInfo),
                            keys : Array(ForeignKeyInfo), extras : CatalogExtras) : DumpedTable
      definition = TableDefinition.new(name)
      id, primary_key, skipped = primary_key_form(infos)
      infos.each do |info|
        next if info.name == skipped
        add_column(definition, info, single_key: primary_key.nil? && id == false && info.primary_key? && infos.count(&.primary_key?) == 1)
      end
      table = DumpedTable.new(name, definition, extras.table_comments[name]?, id, primary_key)
      add_unique_constraints(table, extras.uniques[name]? || [] of CatalogExtras::Unique)
      (extras.exclusions[name]? || [] of CatalogExtras::Exclusion).each { |exclusion| add_exclusion(table, exclusion) }
      add_indexes(table, indexes, extras)
      (extras.checks[name]? || [] of CatalogExtras::Check).each do |check|
        definition.check_constraint(check.expression, check.name)
        if check_name = check.name
          table.explicit_names << check_name if check_name != default_check_name(name, check.expression)
        end
      end
      # Catalog order is arbitrary (SQLite lists the newest key first); sort so a
      # dump is the same text however the schema was created.
      keys.sort_by { |key| {key.columns.join(','), key.to_table} }.each { |key| add_foreign_key(table, key, extras) }
      table
    end

    # `{id:, primary_key:, skipped column}` for the `create_table` call.
    private def primary_key_form(infos : Array(ColumnInfo)) : {Bool | Symbol, (::String | Array(::String))?, ::String?}
      keys = infos.select(&.primary_key?).sort_by!(&.primary_key_position)
      return {false, nil, nil} if keys.empty?
      if keys.size > 1
        return {false, keys.map(&.name), nil}
      end
      key = keys.first
      if key.auto_increment? && key.type_family.integer? && infos.first.name == key.name
        kind = auto_id_kind(key.sql_type)
        return {kind, key.name == "id" ? nil : key.name, key.name}
      end
      if key.type_family.uuid? && (default = key.default) && default.includes?("gen_random_uuid") && infos.first.name == key.name
        return {:uuid, key.name == "id" ? nil : key.name, key.name}
      end
      {false, nil, nil}
    end

    private def auto_id_kind(sql_type : ::String) : Symbol
      type = sql_type.downcase
      if type.includes?("small")
        :smallint
      elsif type.includes?("big") || @dialect.sqlite?
        :bigint
      else
        :integer
      end
    end

    ORDER = [ColumnKind::String, ColumnKind::Text, ColumnKind::Integer, ColumnKind::SmallInt, ColumnKind::BigInt,
             ColumnKind::TinyInt, ColumnKind::Boolean, ColumnKind::Float, ColumnKind::Double, ColumnKind::Decimal,
             ColumnKind::DateTime, ColumnKind::Timestamp, ColumnKind::Time, ColumnKind::Date, ColumnKind::Binary,
             ColumnKind::Json, ColumnKind::Jsonb, ColumnKind::Uuid]

    private def add_column(definition : TableDefinition, info : ColumnInfo, single_key : Bool) : Nil
      default = info.default
      if serial = serial_type(info)
        definition.column(info.name, serial, info.null?, UNSET, nil, nil, nil, nil, info.comment, nil, false, single_key)
      elsif match = matching_kind(info)
        definition.column(info.name, match[0], info.null?, UNSET, default, match[1], match[2], match[3], info.comment, nil, false, single_key)
      else
        definition.column(info.name, info.sql_type, info.null?, UNSET, default, nil, nil, nil, info.comment, nil, false, single_key)
      end
    end

    # The serial type of a non-key PostgreSQL column whose default is a
    # `nextval`, or nil.
    private def serial_type(info : ColumnInfo) : ::String?
      default = info.default
      return if info.primary_key? || !@dialect.pg?
      return unless default && default.starts_with?("nextval(")
      case info.sql_type
      when "bigint"   then "BIGSERIAL"
      when "smallint" then "SMALLSERIAL"
      else                 "SERIAL"
      end
    end

    # The DSL kind whose SQL in this dialect is what the catalog reports, with
    # its `limit`/`precision`/`scale`, or nil to fall back to the raw type.
    private def matching_kind(info : ColumnInfo) : {ColumnKind, Int32?, Int32?, Int32?}?
      wanted = normalize_type(info.sql_type)
      ORDER.each do |kind|
        limit = precision = scale = nil.as(Int32?)
        case kind
        when .string?
          limit = info.limit
        when .decimal?
          precision = info.precision
          scale = info.scale
        when .date_time?, .timestamp?, .time?
          digits = info.sql_type[/\((\d+)\)/, 1]?.try(&.to_i)
          precision = digits unless digits == 6
        end
        candidate = ColumnDefinition.new("probe", kind, true, UNSET, nil, limit, precision, scale)
        begin
          return {kind, limit, precision, scale} if normalize_type(candidate.sql_type(@dialect)) == wanted
        rescue Grant::Schema::UnsupportedOperation | Grant::Schema::InvalidDefinition
          next
        end
      end
      nil
    end

    private def normalize_type(text : ::String) : ::String
      text.downcase.gsub(/\s+/, " ").gsub(", ", ",").gsub(" without time zone", "")
        .gsub("character varying", "varchar").strip
    end

    private def add_unique_constraints(table : DumpedTable, uniques : Array(CatalogExtras::Unique)) : Nil
      uniques.each do |unique|
        table.definition.unique_constraint(unique.columns, unique.name, unique.deferrable)
        if name = unique.name
          table.explicit_names << name if name != Naming.constraint_name("uniq", table.name, unique.columns.join("_"))
        end
      end
    end

    private def default_check_name(table : ::String, expression : ::String) : ::String
      Naming.constraint_name("chk", table, Naming.digest(expression))
    end

    private def add_exclusion(table : DumpedTable, exclusion : CatalogExtras::Exclusion) : Nil
      text = exclusion.definition
      open = text.index('(') || return
      close = TableRebuild::Scanner.matching_paren(text, open) || return
      expression = text[(open + 1)...close]
      method = text[/USING (\w+)/, 1]?
      rest = text[(close + 1)..]
      where = nil.as(::String?)
      if start = rest.index("WHERE (")
        where_open = start + 6
        if where_close = TableRebuild::Scanner.matching_paren(rest, where_open)
          where = rest[(where_open + 1)...where_close]
        end
      end
      deferrable = if rest.includes?("INITIALLY DEFERRED")
                     :deferred
                   elsif rest.includes?("DEFERRABLE")
                     true
                   end
      table.definition.exclusion_constraint(expression, method, where, exclusion.name, deferrable)
      default = Naming.constraint_name("excl", table.name, Naming.digest(expression))
      table.explicit_names << exclusion.name if exclusion.name != default
    end

    private def add_indexes(table : DumpedTable, indexes : Array(IndexInfo), extras : CatalogExtras) : Nil
      backing = table.definition.unique_constraints.map(&.name).to_set
      table.definition.exclusion_constraints.each { |exclusion| backing << exclusion.name }
      indexes.each do |info|
        next if info.name.starts_with?("sqlite_autoindex_")
        next if backing.includes?(info.name)
        text = extras.index_texts[{table.name, info.name}]?
        using = nil.as(::String?)
        orders = {} of ::String => ::String
        classes = {} of ::String => ::String
        covering = [] of ::String
        if text
          using, orders, classes, covering = index_options(text.sql, info)
        elsif descending = extras.index_orders[{table.name, info.name}]?
          orders = descending
        end
        table.definition.indexes << IndexDefinition.new(table.name, info.columns.map { |column| unwrap_expression(column) }, info.name, info.unique?, info.where,
          using, orders, classes, covering, {} of ::String => Int32, nil, false, text.try(&.comment))
      end
    end

    # SQLite reports an expression as `(expr)`; the DSL adds the parentheses.
    private def unwrap_expression(column : ::String) : ::String
      return column if Naming.identifier?(column) || !column.starts_with?('(')
      TableRebuild::Scanner.matching_paren(column, 0) == column.size - 1 ? column[1...-1] : column
    end

    # `{using, order, opclass, include}` read from the index's `CREATE INDEX`
    # text. Only plain column entries carry order and operator classes.
    private def index_options(sql : ::String, info : IndexInfo) : {::String?, Hash(::String, ::String), Hash(::String, ::String), Array(::String)}
      orders = {} of ::String => ::String
      classes = {} of ::String => ::String
      covering = [] of ::String
      on = sql.index(" ON ") || return {nil, orders, classes, covering}
      after_on = sql[(on + 4)..]
      method = after_on[/\A\S+ USING (\w+) /, 1]?
      using = method && method.downcase != "btree" ? method : nil
      open = after_on.index('(') || return {using, orders, classes, covering}
      close = TableRebuild::Scanner.matching_paren(after_on, open) || return {using, orders, classes, covering}
      items = TableRebuild::Scanner.split_items(after_on[(open + 1)...close])
      if items.size == info.columns.size && !info.expression?
        items.each_with_index do |item, position|
          tokens = item.split
          column = info.columns[position]
          rest = tokens[1..]
          descending = false
          skip = false
          rest.each do |token|
            if skip
              skip = false
              next
            end
            case token.upcase
            when "DESC" then descending = true
            when "ASC", "NULLS", "FIRST", "LAST"
            when "COLLATE" then skip = true
            else                classes[column] = token
            end
          end
          orders[column] = "DESC" if descending
        end
      end
      tail = after_on[(close + 1)..]
      if include_list = tail[/\A\s*INCLUDE \(([^)]*)\)/, 1]?
        covering = include_list.split(',').map { |name| TableRebuild::Scanner.unquote(name.strip) }
      end
      {using, orders, classes, covering}
    end

    private def add_foreign_key(table : DumpedTable, info : ForeignKeyInfo, extras : CatalogExtras) : Nil
      key_name = info.name
      deferrable = key_name ? extras.deferrable_keys[{table.name, key_name}]? : nil
      key = ForeignKeyDefinition.new(table.name, info.to_table, info.columns, info.primary_key_columns, info.name,
        action_symbol(info.on_delete), action_symbol(info.on_update), deferrable)
      table.definition.foreign_keys << key
    end

    private def action_symbol(action : ReferentialAction) : Symbol?
      case action
      in .no_action?   then nil
      in .restrict?    then :restrict
      in .cascade?     then :cascade
      in .set_null?    then :set_null
      in .set_default? then :set_default
      end
    end

    # Orders *tables* so every table follows the ones its foreign keys point
    # at. A cycle is broken by moving the keys that point forward into
    # `deferred_foreign_keys`. Ties keep alphabetical order.
    private def order_tables(tables : Array(DumpedTable)) : Array(DumpedTable)
      remaining = tables.sort_by(&.name)
      placed = Set(::String).new
      result = [] of DumpedTable
      until remaining.empty?
        ready = remaining.find { |table| table.depends_on.all? { |name| placed.includes?(name) || remaining.none? { |other| other.name == name } } }
        unless ready
          ready = remaining.first
          pending = ready.definition.foreign_keys.select { |key| key.to_table != ready.name && !placed.includes?(key.to_table) && remaining.any? { |other| other.name == key.to_table } }
          pending.each do |key|
            ready.definition.foreign_keys.delete(key)
            ready.deferred_foreign_keys << key
          end
        end
        remaining.delete(ready)
        placed << ready.name
        result << ready
      end
      result
    end

    private def dump_sqlite_structure(io : IO) : Nil
      sql = "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY rowid"
      @adapter.open(sql) do |db|
        db.query_each(sql) do |rs|
          io << STATEMENT_MARKER << '\n' << rs.read(::String) << ";\n\n"
        end
      end
    end

    private def dump_with_tool(io : IO, command : {::String, Array(::String), Hash(::String, ::String)}) : Nil
      program, arguments, environment = command
      executable = Process.find_executable(program) || raise Grant::Schema::StructureToolError.new("#{program} was not found on the PATH; it is needed to dump the #{@adapter.adapter_name} structure")
      error = IO::Memory.new
      status = Process.run(executable, arguments, env: environment, output: io, error: error)
      raise Grant::Schema::StructureToolError.new("#{program} failed (#{status.exit_code}): #{error.to_s.strip}") unless status.success?
    end

    private def pg_dump_command : {::String, Array(::String), Hash(::String, ::String)}
      connection = ConnectionSettings.parse(@adapter.url)
      arguments = ["--schema-only", "--no-owner", "--no-privileges", "--no-tablespaces"]
      arguments.concat(connection.pg_arguments)
      schema = @adapter.schema.namespace
      arguments << "--schema=#{schema}" if schema
      {"pg_dump", arguments, connection.environment("PGPASSWORD")}
    end

    private def mysqldump_command : {::String, Array(::String), Hash(::String, ::String)}
      connection = ConnectionSettings.parse(@adapter.url)
      arguments = ["--no-data", "--skip-comments", "--skip-add-drop-table"]
      arguments.concat(connection.mysql_arguments)
      {"mysqldump", arguments, connection.environment("MYSQL_PWD")}
    end

    private def current_namespace : ::String
      @adapter.schema.namespace || @adapter.open { |db| db.scalar("SELECT current_schema()").as(::String) }
    end

    private def append_versions(io : IO) : Nil
      versions = SchemaMigration.new(@adapter, @tracking).versions.to_a.sort!
      return if versions.empty?
      table = @dialect.quote(@tracking.micrate? ? SchemaMigration::MICRATE_TABLE : SchemaMigration::TABLE)
      # pg_dump output empties the search_path, so name the schema.
      table = "#{@dialect.quote(current_namespace)}.#{table}" if @dialect.pg?
      io << '\n'
      if @tracking.micrate?
        io << STATEMENT_MARKER << '\n' if @dialect.sqlite?
        values = versions.map { |version| "(#{version}, #{@dialect.quote_literal(true)})" }.join(", ")
        io << "INSERT INTO " << table << " (version_id, is_applied) VALUES " << values << ";\n"
      else
        io << STATEMENT_MARKER << '\n' if @dialect.sqlite?
        io << "INSERT INTO " << table << " (version) VALUES " << versions.map { |version| "('#{version}')" }.join(", ") << ";\n"
      end
    end
  end

  # Raised when `pg_dump`, `psql` or another command line tool is missing or fails.
  class StructureToolError < Grant::ErrorBase
  end

  # The pieces of a database URL a command line tool needs.
  # :nodoc:
  struct ConnectionSettings
    getter host : ::String?
    getter port : Int32?
    getter user : ::String?
    getter password : ::String?
    getter database : ::String

    def initialize(@host : ::String?, @port : Int32?, @user : ::String?, @password : ::String?, @database : ::String)
    end

    def self.parse(url : ::String) : ConnectionSettings
      uri = URI.parse(url)
      database = URI.decode_www_form(uri.path.lstrip('/'))
      new(uri.hostname, uri.port, uri.user.try { |name| URI.decode_www_form(name) },
        uri.password.try { |secret| URI.decode_www_form(secret) }, database)
    end

    # The password goes through the environment, never the argument list.
    def environment(variable : ::String) : Hash(::String, ::String)
      result = {} of ::String => ::String
      if secret = @password
        result[variable] = secret
      end
      result
    end

    def pg_arguments : Array(::String)
      arguments = [] of ::String
      if host = @host
        arguments << "--host=#{host}"
      end
      if port = @port
        arguments << "--port=#{port}"
      end
      if user = @user
        arguments << "--username=#{user}"
      end
      arguments << "--dbname=#{@database}"
      arguments
    end

    # crystal-mysql connects over TCP whenever the URL names a host, while the
    # MySQL tools read `localhost` as "use the Unix socket". `--protocol=TCP`
    # makes the tools reach the same server the adapter does.
    def mysql_arguments : Array(::String)
      arguments = [] of ::String
      if host = @host
        arguments << "--host=#{host}" << "--protocol=TCP"
      end
      if port = @port
        arguments << "--port=#{port}"
      end
      if user = @user
        arguments << "--user=#{user}"
      end
      arguments << @database
      arguments
    end
  end
end
