module Grant::SQLiteEngine::Query
  # A view: its column names (when the CREATE VIEW lists them) and query.
  record ViewInfo, name : String, list_of_column_names : Array(String)?, query : SQL::SelectStatement

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

    alias UserFunction = Array(Value) -> Value

    getter database : Database
    property changes = 0_i64
    property last_insert_rowid = 0_i64
    property total_changes = 0_i64

    @user_functions = {} of String => Hash(Int32, UserFunction)
    @tables = {} of String => TableInfo?
    @views = {} of String => ViewInfo?
    @schema_stamp : {UInt32?, UInt32?} = {nil, nil}

    # The connection's TEMP database (schema "temp"), held in memory and
    # created when a statement first needs it, as C opens it lazily; it
    # goes when the session does.
    getter temp_database : Database? = nil

    # The temp database, created on first use. Inside an open write
    # transaction it joins that transaction, so ROLLBACK undoes its
    # changes with the main file's.
    def temp_database! : Database
      database = @temp_database ||= Database.new(Pager.open_read_write(MemoryFileSystem.new, ":memory:"))
      join_temp_write if @database.pager.in_write_transaction?
      database
    end

    # The database a schema name means: "main", "temp", or nil when the
    # name is no database of this connection.
    def database_named(schema : String) : Database?
      return @database if schema.compare("main", case_insensitive: true) == 0
      return temp_database! if schema.compare("temp", case_insensitive: true) == 0
      nil
    end

    # PRAGMA database_list: main, and temp once it exists.
    def database_list_rows : Array(Array(Value))
      rows = [[0_i64, "main", @database.file_name] of Value]
      rows << [1_i64, "temp", ""] of Value if @temp_database
      rows
    end

    # The schema name of *database* ("main" or "temp").
    def schema_name_of(database : Database) : String
      database.same?(@temp_database) ? "temp" : "main"
    end

    # The schema cookies of the main and temp databases: a statement
    # compiled under other cookies compiles again.
    def schema_stamp : {UInt32?, UInt32?}
      {@database.header.try(&.schema_cookie), @temp_database.try(&.header).try(&.schema_cookie)}
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

    # Compiles the first statement of *sql*.
    def prepare(sql : String) : PreparedQuery
      PreparedQuery.new(self, sql)
    end

    # The table named *name*, or nil: without a *schema*, a TEMP table
    # hides a main table of the same name (sqlite3LocateTable searches
    # temp first).
    def table(name : String, schema : String? = nil) : TableInfo?
      check_schema
      key = "#{schema.try(&.downcase)}\0#{name.downcase}"
      return @tables[key] if @tables.has_key?(key)
      @tables[key] = if schema
                       database = database_named(schema)
                       database ? load_table(name, database, qualified: true) : nil
                     else
                       temp = @temp_database
                       (temp ? load_table(name, temp, qualified: false) : nil) || load_table(name, @database, qualified: false)
                     end
    end

    def view(name : String) : ViewInfo?
      check_schema
      key = name.downcase
      return @views[key] if @views.has_key?(key)
      @views[key] = load_view(name)
    end

    # The databases a name without a schema is looked for in, temp first.
    def list_of_databases : Array(Database)
      temp = @temp_database
      temp ? [temp, @database] : [@database]
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
