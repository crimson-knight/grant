module Grant::SQLiteEngine::Query
  # A view: its column names (when the CREATE VIEW lists them) and query.
  record ViewInfo, name : String, list_of_column_names : Array(String)?, query : SQL::SelectStatement

  # The schema cookies of a connection's databases: main, temp (nil until
  # it exists), and the attached ones in attach order (nil with none
  # attached, so the common stamp allocates nothing). Statements and the
  # session's schema cache compare stamps to see a schema change.
  record SchemaStamp, main : UInt32?, temp : UInt32?, list_of_attached : Array(UInt32?)?

  # A connection to one database for running SQL: the schema as the
  # compiler sees it, the functions the application registered, and the
  # counters `changes()` and `last_insert_rowid()` report.
  #
  # ```
  # session = Grant::SQLiteEngine::Query::Session.new(Grant::SQLiteEngine::Database.open("app.db"))
  # query = session.prepare("SELECT id, email FROM users WHERE id = ?")
  # query.bind(1, 7_i64)
  # while query.step
  #   query.row # => [7_i64, "ada@example.com"]
  # end
  # ```
  class Session
    # The SQLite release whose behavior the engine reproduces.
    SQLITE_VERSION = "3.51.0"

    MASTER_SQL        = "CREATE TABLE sqlite_master(type text,name text,tbl_name text,rootpage int,sql text)"
    MASTER_NAMES      = %w[sqlite_master sqlite_schema]
    TEMP_MASTER_SQL   = "CREATE TABLE sqlite_temp_master(type text,name text,tbl_name text,rootpage int,sql text)"
    TEMP_MASTER_NAMES = %w[sqlite_temp_master sqlite_temp_schema]

    # The name C gives the schema table *name* means in the schema named
    # *schema_name* (sqlite_master, or sqlite_temp_master in temp), or nil
    # when *name* is no schema table; DROP TABLE and ALTER TABLE refuse it
    # by that name.
    def self.schema_table_name(name : String, schema_name : String) : String?
      lower = name.downcase
      if TEMP_MASTER_NAMES.includes?(lower) || (schema_name == "temp" && MASTER_NAMES.includes?(lower))
        "sqlite_temp_master"
      elsif MASTER_NAMES.includes?(lower)
        "sqlite_master"
      end
    end

    alias UserFunction = Array(Value) -> Value

    getter database : Database
    property changes = 0_i64
    property last_insert_rowid = 0_i64
    property total_changes = 0_i64
    # The subtype the running scalar function gave its result
    # (sqlite3_result_subtype), read by FunctionExpr#value_with_subtype.
    property result_subtype = 0_u8
    # The JSON texts the running statement has parsed (json.c's JsonCache).
    getter json_cache : Json::Cache { Json::Cache.new }

    @user_functions = {} of String => Hash(Int32, UserFunction)
    # Tables found by a name without a schema, keyed by the name as the
    # statement spelled it (spellings that differ in case each get an
    # entry), and by schema and name.
    @tables = {} of String => TableInfo?
    @qualified_tables = {} of {String, String} => TableInfo?
    @views = {} of String => ViewInfo?
    @schema_stamp : SchemaStamp? = nil

    # The connection's TEMP database (schema "temp"), held in memory and
    # created when a statement first needs it, as C opens it lazily; it
    # goes when the session does.
    getter temp_database : Database? = nil

    # The databases ATTACH added, in attach order, with their schema names.
    getter list_of_attached = [] of {String, Database}

    # C's limit on attached databases (SQLITE_MAX_ATTACHED).
    MAX_ATTACHED = 10

    # The temp database, created on first use. Inside an open write
    # transaction it joins that transaction, so ROLLBACK undoes its
    # changes with the main file's.
    def temp_database! : Database
      database = @temp_database ||= Database.new(Pager.open_read_write(MemoryFileSystem.new, ":memory:"))
      join_secondary_writes if @database.pager.in_write_transaction?
      database
    end

    # The database a schema name means: "main", "temp", an attached name,
    # or nil when the name is no database of this connection.
    def database_named(schema : String) : Database?
      return @database if schema.compare("main", case_insensitive: true) == 0
      return temp_database! if schema.compare("temp", case_insensitive: true) == 0
      attached_named(schema)
    end

    # The database *schema* names, without bringing the temp database into
    # being: nil for "temp" before it exists, as for an unknown name.
    def existing_database_named(schema : String) : Database?
      return @database if schema.compare("main", case_insensitive: true) == 0
      return @temp_database if schema.compare("temp", case_insensitive: true) == 0
      attached_named(schema)
    end

    private def attached_named(schema : String) : Database?
      found = @list_of_attached.find { |(name, _)| name.compare(schema, case_insensitive: true) == 0 }
      found ? found[1] : nil
    end

    # Whether *schema* names a database of this connection.
    def schema?(schema : String) : Bool
      schema.compare("main", case_insensitive: true) == 0 || schema.compare("temp", case_insensitive: true) == 0 ||
        !attached_named(schema).nil?
    end

    # ATTACH: opens *file* (":memory:" or an empty name for a new database
    # held in memory) as the schema *name* (attachFunc).
    def attach(file : String, name : String) : Nil
      if @list_of_attached.size >= MAX_ATTACHED
        raise SQLError.new("too many attached databases - max #{MAX_ATTACHED}")
      end
      raise SQLError.new("database #{name} is already in use") if schema?(name)
      database = if file.empty? || file == ":memory:"
                   Database.new(Pager.open_read_write(MemoryFileSystem.new, ":memory:"))
                 else
                   begin
                     Database.new(Pager.open_read_write(PosixFileSystem.new, file), File.realpath(file))
                   rescue Error | File::Error
                     raise SQLError.new("unable to open database: #{file}")
                   end
                 end
      DurabilityPragmas.share_with(self, database.pager)
      join_one_write(database) if @database.pager.in_write_transaction?
      @list_of_attached << {name, database}
      reset_schema
    end

    # DETACH: closes the database attached as *name* (detachFunc).
    def detach(name : String) : Nil
      position = @list_of_attached.index { |(attached, _)| attached.compare(name, case_insensitive: true) == 0 }
      unless position
        if name.compare("main", case_insensitive: true) == 0 || name.compare("temp", case_insensitive: true) == 0
          raise SQLError.new("cannot detach database #{name}")
        end
        raise SQLError.new("no such database: #{name}")
      end
      database = @list_of_attached[position][1]
      raise SQLError.new("database #{name} is locked") if database.pager.in_write_transaction?
      @list_of_attached.delete_at(position)
      forget_secondary_marks(database)
      database.close
      reset_schema
    end

    # PRAGMA database_list: main, temp once it exists, then each attached
    # database at its index (C numbers attached databases from 2).
    def database_list_rows : Array(Array(Value))
      rows = [[0_i64, "main", @database.file_name] of Value]
      rows << [1_i64, "temp", ""] of Value if @temp_database
      @list_of_attached.each_with_index do |(name, database), index|
        rows << [(index + 2).to_i64, name, database.file_name] of Value
      end
      rows
    end

    # The schema name of *database*: "main", "temp" or its attached name.
    def schema_name_of(database : Database) : String
      return "temp" if database.same?(@temp_database)
      @list_of_attached.each { |(name, attached)| return name if attached.same?(database) }
      "main"
    end

    # The databases besides main that follow its transactions: temp, once
    # it exists, and the attached ones.
    def list_of_secondary_databases : Array(Database)
      list = [] of Database
      each_secondary_database { |database| list << database }
      list
    end

    # Yields what list_of_secondary_databases holds, without building it.
    def each_secondary_database(& : Database ->) : Nil
      if temp = @temp_database
        yield temp
      end
      @list_of_attached.each { |(_, database)| yield database }
    end

    # The schema cookie of every database, main first: a statement compiled
    # under other cookies compiles again.
    def schema_stamp : SchemaStamp
      main = @database.header.try(&.schema_cookie)
      temp = @temp_database.try(&.header).try(&.schema_cookie)
      return SchemaStamp.new(main, temp, nil) if @list_of_attached.empty?
      SchemaStamp.new(main, temp, @list_of_attached.map { |(_, database)| database.header.try(&.schema_cookie) })
    end

    def initialize(@database : Database)
    end

    @progress_handler : Proc(Bool)? = nil
    @progress_interval = 1
    @progress_count = 0

    # sqlite3_progress_handler: *handler* runs after every *interval* rows
    # the executor steps through; when it returns true the running
    # statement stops with SQLError "interrupted" (SQLITE_INTERRUPT).
    def progress_handler(interval : Int32, &handler : -> Bool) : Nil
      @progress_interval = Math.max(interval, 1)
      @progress_count = 0
      @progress_handler = handler
    end

    def clear_progress_handler : Nil
      @progress_handler = nil
    end

    # Counts one row step and runs the progress handler when it is due.
    def tick : Nil
      handler = @progress_handler
      return unless handler
      @progress_count += 1
      return if @progress_count < @progress_interval
      @progress_count = 0
      raise SQLError.new("interrupted", SQLError::INTERRUPT) if handler.call
    end

    # Registers *name* as a function of *argument_count* arguments (-1 for
    # any number) evaluated by the block.
    def register_function(name : String, argument_count : Int32, &function : UserFunction) : Nil
      (@user_functions[name.downcase] ||= {} of Int32 => UserFunction)[argument_count] = function
    end

    def user_function(name : String, argument_count : Int32) : UserFunction?
      by_count = @user_functions[name.downcase]?
      return unless by_count
      by_count[argument_count]? || by_count[-1]?
    end

    # The frame of a statement run through its plan with no parameters:
    # plans read only a frame's parameters, so one empty frame serves all.
    getter frame_without_parameters : Frame { Frame.new(0, 0, Array(Value).new, self) }

    # The frame a SAVEPOINT or RELEASE read without the parser runs in: its
    # one parameter is the name (the statement itself takes none).
    def savepoint_frame(name : String) : Frame
      frame = @savepoint_frame ||= Frame.new(0, 0, Array(Value).new(1, nil), self)
      frame.list_of_parameters[0] = name
      frame
    end

    @savepoint_frame : Frame?
    @savepoint_shapes = {} of {Bool, Bool} => CompiledSelect

    # The compiled plan every SAVEPOINT (or RELEASE, with or without the
    # SAVEPOINT keyword) of a bare name shares; *statement* is the first
    # one seen, its name replaced by the frame's at each run.
    def savepoint_shape(statement : SQL::Statement) : CompiledSelect
      release = statement.is_a?(SQL::Release)
      keyword = statement.is_a?(SQL::Release) && statement.savepoint_keyword
      @savepoint_shapes[{release, keyword}] ||= begin
        plan = NamedSavepointPlan.new(self, statement, release)
        plan.schema_generation = schema_epoch
        CompiledSelect.new(PlanProducer.new(self, plan, statement, statement.to_sql), plan.list_of_column_names, 0, 0, false)
      end
    end

    # Compiles the first statement of *sql*.
    def prepare(sql : String) : PreparedQuery
      PreparedQuery.new(self, sql)
    end

    # The table named *name*, or nil: without a *schema*, a TEMP table
    # hides a main table of the same name (sqlite3LocateTable searches
    # temp first).
    def table(name : String, schema : String? = nil) : TableInfo?
      check_schema
      if schema
        key = {schema, name}
        return @qualified_tables[key] if @qualified_tables.has_key?(key)
        database = database_named(schema)
        return @qualified_tables[key] = database ? load_table(name, database, qualified: true) : nil
      end
      return @tables[name] if @tables.has_key?(name)
      found = nil
      each_database_in_search_order do |database|
        break if found = load_table(name, database, qualified: false)
      end
      @tables[name] = found
    end

    def view(name : String) : ViewInfo?
      check_schema
      return @views[name] if @views.has_key?(name)
      @views[name] = load_view(name)
    end

    # The databases a name without a schema is looked for in: temp,
    # main, then the attached ones in attach order.
    def list_of_databases : Array(Database)
      list = [] of Database
      each_database_in_search_order { |database| list << database }
      list
    end

    # Yields the databases in the order of list_of_databases without
    # building the list: with no temp database and nothing attached, only
    # main.
    def each_database_in_search_order(& : Database ->) : Nil
      if temp = @temp_database
        yield temp
      end
      yield @database
      @list_of_attached.each { |(_, database)| yield database }
    end

    # The layout of the index named *name*, or nil.
    def index_layout(name : String) : IndexLayout?
      list_of_databases.each do |database|
        next if database.page_count == 0
        entry = database.schema.list_of_indexes.find { |candidate| candidate.object_name.compare(name, case_insensitive: true) == 0 }
        next unless entry
        return table(entry.table_name, schema_name_of(database)).try(&.list_of_indexes.find { |layout| layout.entry.object_name == entry.object_name })
      end
      nil
    end

    # Forgets what was learned about the schema, so the next statement
    # reads it again.
    def reset_schema : Nil
      @tables.clear
      @qualified_tables.clear
      @views.clear
    end

    private def check_schema : Nil
      stamp = schema_stamp
      return if stamp == @schema_stamp
      @schema_stamp = stamp
      reset_schema
    end

    # *qualified*: the statement named the schema.
    private def load_table(name : String, database : Database, qualified : Bool) : TableInfo?
      lower = name.downcase
      temp = database.same?(@temp_database)
      if MASTER_NAMES.includes?(lower) || TEMP_MASTER_NAMES.includes?(lower)
        # Each database's schema table is sqlite_master to a name
        # qualified with it; unqualified, sqlite_master is main's and
        # sqlite_temp_master temp's (whose database then comes into being).
        if TEMP_MASTER_NAMES.includes?(lower)
          return if !temp && qualified
          unless temp
            database = temp_database!
            temp = true
          end
        else
          return if temp && !qualified
        end
        sql = temp ? TEMP_MASTER_SQL : MASTER_SQL
        object_name = temp ? "sqlite_temp_master" : "sqlite_master"
        entry = SchemaEntry.new("table", object_name, object_name, 1_u32, sql)
        return TableInfo.new(entry, TableDefinition.parse(sql), [] of IndexLayout, database)
      end
      return if database.page_count == 0
      entry = database.schema.list_of_entries.find do |candidate|
        candidate.table? && candidate.object_name.compare(name, case_insensitive: true) == 0
      end
      return unless entry
      unless entry.has_a_btree?
        raise UnsupportedSQL.new("virtual table #{entry.object_name}")
      end
      definition = database.schema.table_definition(entry)
      indexes = database.schema.list_of_indexes.select do |index_entry|
        index_entry.table_name.compare(entry.object_name, case_insensitive: true) == 0
      end
      layouts = indexes.map { |index_entry| IndexLayout.build(index_entry, definition, database.text_encoding) }
      TableInfo.new(entry, definition, layouts, database)
    end

    private def load_view(name : String) : ViewInfo?
      return if @database.page_count == 0
      entry = @database.schema.list_of_entries.find do |candidate|
        candidate.object_type == "view" && candidate.object_name.compare(name, case_insensitive: true) == 0
      end
      return unless entry
      sql = entry.sql
      return unless sql
      statement = SQL::Parser.parse_schema(sql)
      return unless statement.is_a?(SQL::CreateView)
      ViewInfo.new(entry.object_name, statement.columns.try(&.map(&.value)), statement.query)
    end
  end
end
