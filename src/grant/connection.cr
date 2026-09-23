module Grant
  # Raw, bound SQL access to a selected Grant database connection.
  #
  # `execute` uses the write role. Read helpers use the model's active read
  # routing or the named connection's reading role. Every operation goes
  # through `Grant::Adapter::Base#open`, so an active transaction or schema
  # tenant keeps using its pinned database connection. Connection calls are
  # explicitly raw and do not apply model default scopes.
  class Connection
    alias AdapterResolver = Proc(Symbol, Grant::Adapter::Base)
    alias BeforeWrite = Proc(Nil)

    @before_write : BeforeWrite

    def initialize(
      @adapter_resolver : AdapterResolver,
      @before_write : BeforeWrite = -> { nil },
    )
    end

    # Returns the adapter selected for *role*. Primarily useful for diagnostics
    # and adapter-aware sanitization.
    def adapter(role : Symbol = :reading) : Grant::Adapter::Base
      @adapter_resolver.call(role)
    end

    # Executes a bound statement on the selected write connection.
    def execute(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : DB::ExecResult
      @before_write.call
      selected_adapter = adapter(:writing)
      statement = selected_adapter.ensure_clause_template(sql)
      selected_adapter.open do |database|
        database.exec(statement, args: binds)
      end
    end

    # Runs a bound query on the selected read connection and buffers its rows.
    def exec_query(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : Grant::Result
      with_result_set(sql, binds) { |result_set| Grant::Result.from(result_set) }
    end

    # Rails-compatible alias for `#exec_query`.
    def select_all(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : Grant::Result
      exec_query(sql, binds)
    end

    # Returns the first result row as a hash, or `nil` when the query has no rows.
    def select_one(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : Grant::Result::HashRow?
      exec_query(sql, binds).to_a.first?
    end

    # Returns the first column of the first result row, or `nil` when absent.
    def select_value(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : DB::Any?
      result = exec_query(sql, binds)
      return if result.rows.empty?
      result.rows.first.first?
    end

    # Returns the first column from every result row.
    def select_values(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : Array(DB::Any)
      result = exec_query(sql, binds)
      result.rows.map(&.first)
    end

    # Returns every result row as positional values.
    def select_rows(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : Array(Grant::Result::Row)
      exec_query(sql, binds).rows
    end

    # Yields the live result set for model hydration without first coercing
    # database values into buffered rows.
    def with_result_set(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type, & : DB::ResultSet -> T) : T forall T
      selected_adapter = adapter(:reading)
      statement = selected_adapter.ensure_clause_template(sql)
      selected_adapter.open do |database|
        database.query(statement, args: binds) do |result_set|
          yield result_set
        end
      end
    end
  end

  # Returns a raw connection facade for a named connection. Read operations use
  # its `:reading` role with the registry's normal fallback; writes use its
  # `:writing` role. The default database is used when *name* is omitted.
  def self.connection(name : String? = nil) : Grant::Connection
    database_name = name || ConnectionRegistry.default_database
    Connection.new(->(role : Symbol) { ConnectionRegistry.get_adapter(database_name, role) })
  end
end
