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

    MASTER_SQL   = "CREATE TABLE sqlite_master(type text,name text,tbl_name text,rootpage int,sql text)"
    MASTER_NAMES = %w[sqlite_master sqlite_schema]

    alias UserFunction = Array(Value) -> Value

    getter database : Database
    property changes = 0_i64
    property last_insert_rowid = 0_i64
    property total_changes = 0_i64

    @user_functions = {} of String => Hash(Int32, UserFunction)
    @tables = {} of String => TableInfo?
    @views = {} of String => ViewInfo?
    @schema_cookie : UInt32? = nil

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

    # The table named *name*, or nil.
    def table(name : String) : TableInfo?
      check_schema
      key = name.downcase
      return @tables[key] if @tables.has_key?(key)
      @tables[key] = load_table(name)
    end

    def view(name : String) : ViewInfo?
      check_schema
      key = name.downcase
      return @views[key] if @views.has_key?(key)
      @views[key] = load_view(name)
    end

    # The layout of the index named *name*, or nil.
    def index_layout(name : String) : IndexLayout?
      entry = @database.schema.list_of_indexes.find { |candidate| candidate.object_name.compare(name, case_insensitive: true) == 0 }
      return unless entry
      table(entry.table_name).try(&.list_of_indexes.find { |layout| layout.entry.object_name == entry.object_name })
    end

    # Forgets what was learned about the schema, so the next statement
    # reads it again.
    def reset_schema : Nil
      @tables.clear
      @views.clear
    end

    private def check_schema : Nil
      cookie = @database.header.try(&.schema_cookie)
      return if cookie == @schema_cookie
      @schema_cookie = cookie
      reset_schema
    end

    private def load_table(name : String) : TableInfo?
      if MASTER_NAMES.includes?(name.downcase)
        entry = SchemaEntry.new("table", "sqlite_master", "sqlite_master", 1_u32, MASTER_SQL)
        return TableInfo.new(entry, TableDefinition.parse(MASTER_SQL), [] of IndexLayout)
      end
      return if @database.page_count == 0
      entry = @database.schema.list_of_entries.find do |candidate|
        candidate.table? && candidate.object_name.compare(name, case_insensitive: true) == 0
      end
      return unless entry
      unless entry.has_a_btree?
        raise UnsupportedSQL.new("virtual table #{entry.object_name}")
      end
      definition = @database.schema.table_definition(entry)
      indexes = @database.schema.list_of_indexes.select do |index_entry|
        index_entry.table_name.compare(entry.object_name, case_insensitive: true) == 0
      end
      layouts = indexes.map { |index_entry| IndexLayout.build(index_entry, definition, @database.text_encoding) }
      TableInfo.new(entry, definition, layouts)
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
