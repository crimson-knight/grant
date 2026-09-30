require "../grant"
require "db"
require "colorize"
require "../grant/error_taxonomy"
require "./error_translator"
require "./placeholder_scanner"
require "./server_version"
require "./pool_support"
require "../grant/advisory_lock"

# The Base Adapter specifies the interface that will be used by the model
# objects to perform actions against a specific database.  Each adapter needs
# to implement these methods.
abstract class Grant::Adapter::Base
  getter name : String
  getter url : String
  private property _database : DB::Database?
  @database_version : Grant::ServerVersion?
  @database_mutex = Mutex.new

  # Pool behavior the registry copies from the connection's spec. A bare
  # adapter built by hand keeps these defaults.
  property retry_attempts : Int32 = 1
  property retry_delay : Time::Span = 0.2.seconds
  property statement_limit : Int32 = 1000
  property idle_timeout : Time::Span? = nil
  property min_connections : Int32 = 0
  property keepalive : Time::Span? = nil
  property max_age : Time::Span? = nil

  # Checkouts in progress and fibers blocked waiting for one. Plain atomics, so
  # reading pool statistics or picking a replica never takes a lock.
  @active_checkouts = Atomic(Int32).new(0)
  @waiting_checkouts = Atomic(Int32).new(0)
  @last_used_ticks = Atomic(Int64).new(Grant::Adapter::PoolSupport.ticks)

  private SQL_KEYWORDS = Set(String).new(%w(
    ALTER AND ANY AS ASC COLUMN CONSTRAINT COUNT CREATE DEFAULT DELETE DESC
    DISTINCT DROP ELSE EXISTS FALSE FOREIGN FROM GROUP HAVING IF IN INDEX INNER
    INSERT INTO JOIN LIMIT NOT NULL ON OR ORDER PRIMARY REFERENCES RELEASE RETURNING
    SELECT SET TABLE THEN TRUE UNION UNIQUE UPDATE USING VALUES WHEN WHERE
  ))

  def initialize(@name : String, @url : String)
  end

  # Adapters convert Grant values at the bind boundary when their drivers do
  # not accept the model type directly.
  def normalize_bind_value(value)
    value
  end

  def normalize_bind_values(values)
    values.map { |value| normalize_bind_value(value) }
  end

  def read_time(result : DB::ResultSet) : Time
    result.read(Time)
  end

  def read_nullable_time(result : DB::ResultSet) : Time?
    result.read(Time?)
  end

  # Normalizes one buffered result value into Grant's stable result union.
  def normalize_result_value(value) : Grant::Result::Value
    Grant::Result.normalize(value)
  end

  def postgres? : Bool
    false
  end

  def mysql? : Bool
    false
  end

  def sqlite? : Bool
    false
  end

  # True when the adapter talks to a database server over the network. Such
  # adapters keep as many idle connections as the pool allows. SQLite
  # overrides this.
  def self.server_adapter? : Bool
    true
  end

  # True when *url* names a database that lives only inside one connection, so
  # the pool must hold exactly one. SQLite overrides this for `:memory:`.
  def self.single_connection_url?(url : String) : Bool
    false
  end

  # True when the driver can run statements without preparing them. SQLite
  # cannot, and ignores `prepared_statements: false`.
  def self.supports_unprepared_statements? : Bool
    true
  end

  # The connection pool, opened on first use.
  def database : DB::Database
    @_database || open_database
  end

  private def open_database : DB::Database
    @database_mutex.synchronize do
      @_database ||= begin
        opened = DB.open(@url)
        limit = @statement_limit
        opened.setup_connection { |conn| conn.statement_cache_limit = limit } if limit > 0
        opened
      end
    end
  end

  # True once the pool has been opened and not since closed by `#disconnect!`.
  def connected? : Bool
    !@_database.nil?
  end

  # Closes the pool and every connection in it. The adapter opens a fresh pool
  # the next time something needs a connection, so a reference that outlives
  # this call keeps working instead of failing.
  def disconnect! : Nil
    closing = @database_mutex.synchronize do
      current = @_database
      @_database = nil
      current
    end
    closing.try(&.close)
  end

  # Drops the pool and opens a new one, then checks it can reach the server.
  # Raises `Grant::ConnectionFailed` when it cannot.
  def reconnect! : Nil
    disconnect!
    verify!
  end

  # Runs `SELECT 1` on a pooled connection, raising the driver's error when it
  # fails. It skips retries, transactions and pinned connections so it reports
  # on the pool itself. A pool whose every connection is checked out counts as
  # alive: waiting for a free connection is not an outage.
  def ping : Nil
    stats = database.pool.stats
    return if stats.max_connections > 0 && stats.idle_connections == 0 &&
              stats.open_connections >= stats.max_connections

    checked_out { |conn| conn.scalar("SELECT 1") }
  end

  # Raises `Grant::ConnectionFailed` unless the server answers `SELECT 1`.
  def verify! : Nil
    ping
  rescue ex : ::Exception
    translated = translate_exception(ex)
    raise translated if translated.is_a?(Grant::ConnectionNotEstablished)
    raise Grant::ConnectionFailed.new("Could not reach #{name}: #{ex.message}", cause: ex)
  end

  # True when the server answers `SELECT 1`.
  def active? : Bool
    verify!
    true
  rescue Grant::ConnectionNotEstablished
    false
  end

  # Pool statistics, read without a lock. An adapter whose pool is not open
  # reports zeros.
  def pool_stat : Grant::PoolStat
    waiting = @waiting_checkouts.get
    if opened = @_database
      stats = opened.pool.stats
      Grant::PoolStat.new(
        size: stats.max_connections,
        connections: stats.open_connections,
        busy: stats.open_connections - stats.idle_connections,
        idle: stats.idle_connections,
        waiting: waiting,
        in_flight: stats.in_flight_connections)
    else
      Grant::PoolStat.new(size: 0, connections: 0, busy: 0, idle: 0, waiting: waiting, in_flight: 0)
    end
  end

  # Checkouts currently held, which the least-connections replica strategy
  # compares.
  def active_checkouts : Int32
    @active_checkouts.get
  end

  # Milliseconds on the monotonic clock at the last checkout.
  def last_used_ticks : Int64
    @last_used_ticks.get
  end

  # Closes idle connections, keeping at least *keep* open. Returns how many it
  # closed. Each connection is taken from the pool and closed on its own, so
  # the pool is never locked across network I/O.
  def close_idle_connections(keep : Int32 = 0) : Int32
    return 0 unless opened = @_database

    closed = 0
    loop do
      stats = opened.pool.stats
      break if stats.idle_connections == 0 || stats.open_connections <= keep

      connection = opened.checkout
      connection.close
      connection.release
      closed += 1
    end
    closed
  end

  # Closes idle connections that have been open longer than `max_age`, so the
  # pool turns its connections over (for example ahead of a proxy that drops
  # old ones). A connection checked out when it passes `max_age` is closed as
  # it is returned. Returns how many idle connections it closed.
  def close_aged_connections : Int32
    return 0 unless opened = @_database
    return 0 unless @max_age

    held = [] of DB::Connection
    opened.pool.stats.idle_connections.times do
      break if opened.pool.stats.idle_connections == 0
      held << opened.checkout
    end

    closed = 0
    held.each do |connection|
      if aged?(connection)
        connection.close
        closed += 1
      end
      connection.release
    end
    closed
  end

  # Runs `SELECT 1` on every idle connection so a server or proxy that drops
  # idle sockets is noticed before a request needs one. Returns the number of
  # connections that answered.
  def keepalive_idle_connections : Int32
    return 0 unless opened = @_database

    idle = opened.pool.stats.idle_connections
    held = [] of DB::Connection
    idle.times do
      break if opened.pool.stats.idle_connections == 0
      held << opened.checkout
    end

    alive = 0
    held.each do |connection|
      begin
        connection.scalar("SELECT 1")
        alive += 1
      rescue ::Exception
        connection.close
      ensure
        connection.release
      end
    end
    alive
  end

  # Yields a raw connection for the current context.
  #
  # Failures raised by the driver are translated into the `Grant::ErrorBase`
  # taxonomy (see `#translate_exception`). Pass *sql* and *binds* so the
  # translated error can report the failing statement; both are only read on
  # the error path.
  #
  # When a `Grant::Events::SQL` subscriber is registered and *sql* is given, the
  # statement is timed and published once the block ends (also when it raised).
  # *name* labels the event, usually with the model that issued the statement.
  def open(sql : String? = nil, binds = nil, name : String? = nil, &)
    if sql && Grant::Notifications.subscribed?(Grant::Events::SQL)
      started = Time.instant
      begin
        return open_routed(sql, binds) { |conn| yield conn }
      ensure
        Grant::Notifications.publish_sql(self, sql, binds, Time.instant - started, name)
        Grant::QueryCache.invalidate! unless Grant::Adapter::PoolSupport.idempotent_read?(sql)
      end
    end

    begin
      open_routed(sql, binds) { |conn| yield conn }
    ensure
      # Anything but a plain read may have changed data, so query caches drop
      # their entries (also for a write made on another connection).
      Grant::QueryCache.invalidate! unless Grant::Adapter::PoolSupport.idempotent_read?(sql)
    end
  end

  private def open_routed(sql : String?, binds, &)
    # A schema-tenant block owns one pool connection for its lifetime. Check it
    # before transaction routing so a model on another adapter cannot bypass
    # the tenant context merely because that adapter already has a transaction.
    if schema_conn = Grant::SchemaTenant.current_connection?(self)
      begin
        return yield schema_conn
      rescue ex : ::Exception
        raise translate_exception(ex, sql, binds)
      end
    end

    # If the current fiber has an open transaction THAT THIS ADAPTER started,
    # reuse that connection so all DML issued inside the transaction block runs
    # on the same connection as BEGIN/COMMIT — making the transaction truly
    # atomic.  DML through a different adapter (multi-database setups) is not
    # part of this transaction and checks out from its own pool.
    if tx_conn = Grant::Transaction.current_connection?(self)
      begin
        return yield tx_conn
      rescue ex : ::Exception
        raise translate_exception(ex, sql, binds)
      end
    end

    # A connection pinned by `#with_connection` serves every statement of its
    # block, so session state such as temp tables or advisory locks survives
    # from one statement to the next.
    if pinned = pinned_connection?
      begin
        return yield pinned
      rescue ex : ::Exception
        raise translate_exception(ex, sql, binds)
      end
    end

    open_pool_connection(sql, binds) { |conn| yield conn }
  end

  # Yields one raw driver connection and keeps every Grant statement this fiber
  # issues on this adapter on it until the block ends. Inside a transaction or
  # schema-tenant block the connection they already own is yielded instead.
  #
  # The connection is held for the whole block, so keep slow non-database work
  # out of it: a fiber that idles while holding a connection starves the pool.
  def with_connection(& : DB::Connection -> T) : T forall T
    owned = Grant::SchemaTenant.current_connection?(self) ||
            Grant::Transaction.current_connection?(self) ||
            pinned_connection?
    return yield owned if owned

    open_pool_connection do |conn|
      pins = (Fiber.current.grant_pinned_connections ||= {} of UInt64 => DB::Connection)
      pins[object_id] = conn
      begin
        yield conn
      ensure
        pins.delete(object_id)
      end
    end
  end

  # The connection `#with_connection` pinned for this fiber, if any.
  def pinned_connection? : DB::Connection?
    Fiber.current.grant_pinned_connections.try(&.[object_id]?)
  end

  # Always checks out a fresh connection from the pool, bypassing the
  # transaction-routing logic in #open.  Used by execute_transaction so that
  # requires_new: true transactions get their own independent connection rather
  # than inheriting an enclosing transaction's connection.
  #
  # A failure to connect is retried up to `retry_attempts` times with capped
  # exponential backoff, since nothing was sent. A connection that drops while
  # the block runs is retried once only when *sql* is a plain read; anything
  # else could already have taken effect, so it raises
  # `Grant::ConnectionFailed` instead.
  def open_pool_connection(sql : String? = nil, binds = nil, &)
    lost_retries = Grant::Adapter::PoolSupport.idempotent_read?(sql) ? Math.min(@retry_attempts, 1) : 0
    attempt = 0
    loop do
      begin
        return checked_out { |conn| yield conn }
      rescue ex : ::DB::ConnectionLost
        raise ex if lost_retries == 0
        lost_retries -= 1
        sleep Grant::Adapter::PoolSupport.backoff(@retry_delay, attempt)
        attempt += 1
      end
    end
  rescue ex : ::Exception
    raise translate_exception(ex, sql, binds)
  end

  private def checked_out(&)
    connection = checkout_connection
    @active_checkouts.add(1)
    @last_used_ticks.set(Grant::Adapter::PoolSupport.ticks)
    begin
      yield connection
    rescue ex : IO::Error
      raise ::DB::ConnectionLost.new(connection)
    rescue ex : ::Exception
      if ex.message =~ /client was disconnected/
        raise ::DB::ConnectionLost.new(connection)
      else
        raise ex
      end
    ensure
      @active_checkouts.sub(1)
      connection.close if aged?(connection)
      connection.release
    end
  end

  # True when *connection* has been open longer than `max_age`.
  private def aged?(connection : DB::Connection) : Bool
    return false unless limit = @max_age

    Grant::Adapter::PoolSupport.ticks - connection.grant_opened_ticks >= limit.total_milliseconds
  end

  # Takes a connection from the pool, counting the fiber as waiting while it
  # blocks and retrying a refused connection with backoff.
  private def checkout_connection : DB::Connection
    attempt = 0
    @waiting_checkouts.add(1)
    begin
      loop do
        begin
          return database.checkout
        rescue ex : ::DB::PoolResourceRefused
          raise ex if attempt >= @retry_attempts
          sleep Grant::Adapter::PoolSupport.backoff(@retry_delay, attempt)
          attempt += 1
        end
      end
    ensure
      @waiting_checkouts.sub(1)
    end
  end

  # Maps a driver failure to the matching `Grant::ErrorBase` subclass and
  # returns it. An exception Grant does not recognize is returned unchanged, so
  # control-flow exceptions and unknown driver errors keep propagating as they
  # were. Adapters override this to classify their driver's errors and call
  # `super` for the rest.
  #
  # Only called from a `rescue`, so it costs nothing when statements succeed.
  def translate_exception(ex : ::Exception, sql : String? = nil, binds = nil) : ::Exception
    Grant::Adapter::ErrorTranslator.translate_pool_error(ex) || ex
  end

  def log(query : String, elapsed_time : Time::Span, params = [] of String) : Nil
    Grant::Logs::SQL.debug { colorize query, Grant::Encryption::LogFilter.redact(query, params), elapsed_time.total_seconds }
  end

  # remove all rows from a table and reset the counter on the id.
  abstract def clear(table_name : String)

  # ---------------------------------------------------------------------------
  # Test-support helpers
  #
  # Reset and load data without tripping constraints. They are safe to call in
  # production code but exist for suites and fixture loaders; the transactional
  # spec wrapper in `Grant::Spec` is cheaper than truncating between examples.
  # ---------------------------------------------------------------------------

  # Runs *block* with foreign key checks switched off and returns its value.
  #
  # The block runs inside a transaction (joining the open one), because the
  # setting must live on the connection the block's statements use. PostgreSQL
  # skips the checks entirely (`session_replication_role = replica`, which needs
  # superuser or a granted privilege). SQLite defers them to the commit, so rows
  # may be inserted in any order as long as the set is consistent when the
  # transaction ends. MySQL switches `FOREIGN_KEY_CHECKS` off for the session.
  #
  # ```
  # adapter.disable_referential_integrity do
  #   Post.create!(author_id: 99) # author 99 is loaded next, or not at all on PG/MySQL
  # end
  # ```
  def disable_referential_integrity(& : -> T) : T? forall T
    unless supports_disable_referential_integrity?
      raise Grant::ErrorBase.new("#{adapter_name} cannot disable referential integrity")
    end

    Grant::Transaction.run(self, Grant::Transaction::Options.new) do
      exec_control_statement(referential_integrity_off_sql)
      value = begin
        yield
      rescue ex
        begin
          restore_referential_integrity
        rescue restore_error
          # The block's error is the one to report; an aborted transaction
          # (PostgreSQL) rejects the restore and resets the setting anyway.
          Grant::Log.warn(exception: restore_error) { "Could not restore referential integrity after a failed block" }
        end
        raise ex
      end
      restore_referential_integrity
      value
    end
  end

  # Empties every table in *names* in one call and restarts their id counters.
  # Rows that other tables reference are handled per adapter: PostgreSQL uses
  # `TRUNCATE ... RESTART IDENTITY CASCADE` (and so also empties tables that
  # reference the listed ones); SQLite and MySQL switch foreign keys off first.
  def truncate_tables(*names : String) : Nil
    truncate_tables(names.to_a)
  end

  # :ditto:
  def truncate_tables(names : Array(String)) : Nil
    return if names.empty?

    disable_referential_integrity do
      truncate_statements(names).each { |statement| open(statement) { |conn| conn.exec(statement) } }
    end
  end

  # Moves the id counter of *table_name* to one past the highest existing
  # *primary_key*, so the next insert cannot collide with rows that were loaded
  # with explicit ids. A table without a counter is left alone.
  def reset_pk_sequence!(table_name : String, primary_key : String = "id") : Nil
    raise Grant::ErrorBase.new("#{self.class} does not implement #reset_pk_sequence!")
  end

  # SQL that switches foreign key enforcement off for the current transaction.
  protected def referential_integrity_off_sql : String
    raise Grant::ErrorBase.new("#{self.class} does not implement #disable_referential_integrity")
  end

  # SQL that turns it back on, or `nil` when the transaction end does it.
  protected def referential_integrity_on_sql : String?
    nil
  end

  # Statements that empty *names*; the default deletes row by row.
  protected def truncate_statements(names : Array(String)) : Array(String)
    names.map { |name| "DELETE FROM #{quote(name)}" }
  end

  # Runs a session control statement (no rows, not reported as a query).
  protected def exec_control_statement(statement : String) : Nil
    open { |conn| conn.exec(statement) }
  end

  private def restore_referential_integrity : Nil
    if statement = referential_integrity_on_sql
      exec_control_statement(statement)
    end
  end

  # select performs a query against a table.  The query object contains table_name,
  # fields (configured using the sql_mapping directive in your model), and an optional
  # raw query string.  The clause and params is the query and params that is passed
  # in via .all() method
  def select(query : Grant::Select::Container, clause = "", params = [] of DB::Any, &)
    clause = ensure_clause_template(clause)
    statement = query.custom ? "#{query.custom} #{clause}" : String.build do |stmt|
      stmt << "SELECT "
      stmt << query.fields.map { |name| "#{quote(query.table_name)}.#{quote(name)}" }.join(", ")
      stmt << " FROM #{quote(query.table_name)} #{clause}"
    end

    elapsed_time = Time.measure do
      open(statement, params) do |db|
        db.query statement, args: normalize_bind_values(params) do |rs|
          yield rs
        end
      end
    end

    log statement, elapsed_time, params
  end

  # Returns `true` if a record exists that matches *criteria*, otherwise `false`.
  def exists?(table_name : String, criteria : String, params = [] of Grant::Columns::Type) : Bool
    statement = "SELECT EXISTS(SELECT 1 FROM #{table_name} WHERE #{ensure_clause_template(criteria)})"

    exists = false
    elapsed_time = Time.measure do
      open(statement, params) do |db|
        exists = db.query_one?(statement, args: normalize_bind_values(params), as: Bool) || exists
      end
    end

    log statement, elapsed_time, params

    exists
  end

  # Converts placeholder characters in a SQL clause to the adapter's
  # native parameter syntax. SQLite and MySQL use `?` natively, so the base
  # implementation only collapses the `??` escape. The PG adapter overrides
  # this to convert `?` to `$1`, `$2`, etc.
  #
  # `??` is the escape for a literal `?` on every adapter, and a `?` inside a
  # quoted literal or comment is never treated as a placeholder.
  def ensure_clause_template(clause : String, starting_index : Int32 = 0) : String
    Grant::Adapter::PlaceholderScanner.rewrite(clause, starting_index, numbered: false)
  end

  # Returns the placeholder for the *index*th bound parameter. Adapters with
  # positional question-mark placeholders ignore the index; PostgreSQL uses it
  # to keep composed SQL fragments from reusing an earlier parameter number.
  def parameter_placeholder(index : Int32) : String
    "?"
  end

  # Quotes a boolean as a SQL literal for this adapter. PostgreSQL and SQLite
  # accept `TRUE`/`FALSE`; the base implementation uses the portable `1`/`0`
  # form (which MySQL prefers). Adapters override where they differ.
  #
  # Used by `Grant::Sanitization` for inline (non-parameterized) SQL only.
  # Parameter binding remains the preferred path.
  def quote_boolean(value : Bool) : String
    value ? "1" : "0"
  end

  # ---------------------------------------------------------------------------
  # Multi-row insert clause builders, used by `insert_all` and `upsert_all`.
  # ---------------------------------------------------------------------------

  # The most bind parameters one statement may carry. Bulk writes split their
  # rows into chunks that stay under this cap.
  def bulk_bind_limit : Int32
    65_535
  end

  # How many rows of *column_count* columns fit in one statement.
  def bulk_chunk_rows(column_count : Int32) : Int32
    raise ArgumentError.new("A bulk write needs at least one column") if column_count < 1
    if column_count > bulk_bind_limit
      raise ArgumentError.new("A bulk write of #{column_count} columns exceeds the #{bulk_bind_limit} bind parameter limit of one row")
    end
    bulk_bind_limit // column_count
  end

  # One `INSERT` for *row_count* rows: a single multi-row `VALUES` list, the
  # adapter's conflict clause, and `RETURNING` when *returning* names columns.
  def bulk_insert_sql(table_name : String, columns : Array(String), row_count : Int32,
                      conflict : Grant::Bulk::Conflict, returning : Array(String)?) : String
    String.build do |sql|
      sql << "INSERT INTO " << quote(table_name) << " ("
      columns.each_with_index do |column, index|
        sql << ", " unless index == 0
        sql << quote(column)
      end
      sql << ") VALUES "
      position = 0
      row_count.times do |row|
        sql << ", " unless row == 0
        sql << '('
        columns.size.times do |column|
          sql << ", " unless column == 0
          position += 1
          sql << parameter_placeholder(position)
        end
        sql << ')'
      end
      sql << bulk_conflict_sql(table_name, conflict, columns)
      sql << bulk_returning_sql(returning) if returning && !returning.empty?
    end
  end

  # The `ON CONFLICT` form shared by PostgreSQL and SQLite. MySQL overrides it.
  protected def bulk_conflict_sql(table_name : String, conflict : Grant::Bulk::Conflict, columns : Array(String)) : String
    case conflict.mode
    in .raise?
      ""
    in .skip?
      " ON CONFLICT#{bulk_conflict_target(conflict)} DO NOTHING"
    in .update?
      assignments = bulk_update_assignments(conflict) { |column| "EXCLUDED.#{quote(column)}" }
      if assignments.empty?
        " ON CONFLICT#{bulk_conflict_target(conflict)} DO NOTHING"
      else
        " ON CONFLICT#{bulk_conflict_target(conflict)} DO UPDATE SET #{assignments}#{bulk_update_guard(table_name, conflict)}"
      end
    end
  end

  # Restricts `DO UPDATE` to existing rows whose guard column (the tenant
  # column) matches the incoming row.
  protected def bulk_update_guard(table_name : String, conflict : Grant::Bulk::Conflict) : String
    column = conflict.guard_column
    return "" unless column
    " WHERE #{quote(table_name)}.#{quote(column)} = EXCLUDED.#{quote(column)}"
  end

  protected def bulk_conflict_target(conflict : Grant::Bulk::Conflict) : String
    return "" if conflict.target.empty?
    " (#{conflict.target.map { |column| quote(column) }.join(", ")})"
  end

  # The `SET` list of an upsert: the caller's fragment, or one assignment per
  # updatable column built from the block's incoming-value expression.
  protected def bulk_update_assignments(conflict : Grant::Bulk::Conflict, & : String -> String) : String
    if fragment = conflict.update_sql
      return fragment.sql
    end
    conflict.update_columns.map { |column| "#{quote(column)} = #{yield column}" }.join(", ")
  end

  protected def bulk_returning_sql(returning : Array(String)) : String
    " RETURNING #{returning.map { |column| quote(column) }.join(", ")}"
  end

  # Column names of the unique index *index_name* on *table_name*, in index
  # order, or nil when no such index exists.
  def unique_index_columns(table_name : String, index_name : String) : Array(String)?
    raise ArgumentError.new("#{self.class} cannot resolve the index #{index_name.inspect}; pass the column names to unique_by instead")
  end

  # This will insert a row in the database and return the id generated.
  abstract def insert(table_name : String, fields, params, lastval) : Int64

  # This will insert an array of models as one insert statement
  abstract def import(table_name : String, primary_name : String, auto : Bool, fields, model_array, **options)

  # This will update a row in the database.
  abstract def update(table_name : String, primary_name : String, fields, params)

  # Update with custom WHERE clause for composite keys
  def update_with_where(table_name : String, fields : Array(String), params : Array(DB::Any), where_clause : String)
    statement = String.build do |stmt|
      stmt << "UPDATE #{quote(table_name)} SET "
      stmt << fields.map { |field| "#{quote(field)} = ?" }.join(", ")
      stmt << " WHERE #{where_clause}"
    end
    statement = ensure_clause_template(statement)

    elapsed_time = Time.measure do
      open(statement, params) do |db|
        db.exec statement, args: normalize_bind_values(params)
      end
    end

    log statement, elapsed_time, params
  end

  # Atomically adds *amount* to one column for rows matching *where_clause*.
  # The `where_clause` includes its WHERE keyword. Its placeholders and
  # parameters are shifted after the amount parameter for PostgreSQL.
  def increment_with_where(
    table_name : String,
    field_name : String,
    amount : Grant::Columns::Type,
    where_clause : String,
    where_params : Array(Grant::Columns::Type),
  ) : Int64
    field = quote(field_name)
    shifted_where_clause = shift_parameter_placeholders(where_clause, 1)
    statement = "UPDATE #{quote(table_name)} SET #{field} = COALESCE(#{field}, 0) + #{parameter_placeholder(1)} #{shifted_where_clause}"
    parameters = [] of Grant::Columns::Type
    parameters << amount
    parameters.concat(where_params)

    affected = 0_i64
    elapsed_time = Time.measure do
      open(statement, parameters) do |db|
        result = db.exec(statement, args: normalize_bind_values(parameters))
        affected = rows_affected_after_write(db, result)
      end
    end

    log statement, elapsed_time, parameters
    affected
  end

  private def shift_parameter_placeholders(clause : String, offset : Int32) : String
    clause.gsub(/\$(\d+)/) do |match|
      "$#{match[1..].to_i + offset}"
    end
  end

  # This will delete a row from the database.
  abstract def delete(table_name : String, primary_name : String, value)

  # Deletes one row and returns its affected-row count.
  def delete_with_rows_affected(table_name : String, primary_name : String, value : Grant::Columns::Type) : Int64
    statement = "DELETE FROM #{quote(table_name)} WHERE #{quote(primary_name)} = ?"
    statement = ensure_clause_template(statement)
    affected = 0_i64
    elapsed_time = Time.measure do
      open(statement, [value]) do |db|
        result = db.exec(statement, args: normalize_bind_values([value]))
        affected = rows_affected_after_write(db, result)
      end
    end

    log statement, elapsed_time, value
    affected
  end

  # Returns the number of rows affected by a completed write. SQLite overrides
  # this because its driver does not report the count on DB::ExecResult.
  def rows_affected_after_write(db, result : DB::ExecResult) : Int64
    result.rows_affected
  end

  # Delete with custom WHERE clause for composite keys
  def delete_with_where(table_name : String, where_clause : String, params : Array(DB::Any))
    statement = "DELETE FROM #{quote(table_name)} WHERE #{ensure_clause_template(where_clause)}"

    elapsed_time = Time.measure do
      open(statement, params) do |db|
        db.exec statement, args: normalize_bind_values(params)
      end
    end

    log statement, elapsed_time, params
  end

  module Schema
    TYPES = {
      "Bool"    => "BOOL",
      "Float32" => "FLOAT",
      "Float64" => "REAL",
      "Int32"   => "INT",
      "Int64"   => "BIGINT",
      "String"  => "VARCHAR(255)",
      "Time"    => "TIMESTAMP",
    }
  end

  # Use macro in order to read a constant defined in each subclasses.
  macro inherited
    # quotes table and column names
    #
    # Embedded quoting characters are doubled so an identifier sourced from
    # user input cannot break out of the quoted identifier (e.g. a column name
    # containing `"`). This is the adapter-level building block used by
    # `Grant::Sanitization.quote_identifier`.
    def quote(name : String) : String
      String.build do |str|
        name.split('.').each_with_index do |part, index|
          str << '.' unless index == 0
          str << QUOTING_CHAR
          str << part.gsub(QUOTING_CHAR, "#{QUOTING_CHAR}#{QUOTING_CHAR}")
          str << QUOTING_CHAR
        end
      end
    end

    # converts the crystal class to database type of this adapter
    def self.schema_type?(key : String) : String?
      Schema::TYPES[key]? || Grant::Adapter::Base::Schema::TYPES[key]?
    end
  end

  private def colorize(query : String, params, elapsed_time : Float64) : String
    q = query.to_s.split(/([a-zA-Z0-9_$']+)/).map do |word|
      if SQL_KEYWORDS.includes?(word.upcase)
        word.colorize.bold.blue.to_s
      elsif !word.starts_with?('$') && word =~ /\d+/
        word.colorize.light_red
      elsif word.starts_with?('\'') && word.ends_with?('\'')
        word.colorize(Colorize::Color256.new(193))
      else
        word.colorize.white
      end
    end.join

    "[#{humanize_duration(elapsed_time)}] #{q}: #{params.colorize.light_magenta}"
  end

  private def humanize_duration(elapsed_time : Float64)
    if elapsed_time > 0.1
      "#{(elapsed_time).*(100).trunc./(100)}s".colorize.red
    elsif elapsed_time > 0.001
      "#{(elapsed_time * 1_000).trunc}ms".colorize.yellow
    elsif elapsed_time > 0.000_001
      "#{(elapsed_time * 1_000_000).trunc}µs".colorize.green
    elsif elapsed_time > 0.000_000_001
      "#{(elapsed_time * 1_000_000_000).trunc}ns".colorize.green
    else
      "<1ns".colorize.green
    end
  end

  # Human readable name of the database product, for example "PostgreSQL".
  def adapter_name : String
    self.class.name
  end

  # Server release, fetched on first use and cached for the adapter's life so
  # version gated capability predicates never query per call.
  def database_version : Grant::ServerVersion
    @database_version ||= fetch_database_version
  end

  # Pins the server version without connecting. Use it for tooling that
  # inspects capabilities offline, or when the server is upgraded in place and
  # the cache must be refreshed.
  def database_version=(version : Grant::ServerVersion) : Grant::ServerVersion
    @database_version = version
  end

  # Name of the database the connection is using.
  def current_database : String
    raise Grant::ErrorBase.new("#{self.class} does not implement #current_database")
  end

  # Asks the server for its version. Adapters override this.
  protected def fetch_database_version : Grant::ServerVersion
    raise Grant::ErrorBase.new("#{self.class} does not implement #fetch_database_version")
  end

  # ---------------------------------------------------------------------------
  # Capability predicates
  #
  # Each predicate answers "can this database do X?" so callers branch on a
  # capability instead of on the adapter class. The base answers `false`;
  # adapters override with a constant, or with a check against the cached
  # `#database_version` when the answer depends on the server release.
  # `docs/adapter_matrix.md` lists every answer.
  # ---------------------------------------------------------------------------

  # `INSERT ... RETURNING` (or an equivalent that yields written columns).
  def supports_insert_returning? : Bool
    false
  end

  # Skipping rows that hit a unique key: `ON CONFLICT DO NOTHING`, `INSERT IGNORE`.
  def supports_insert_on_duplicate_skip? : Bool
    false
  end

  # Updating the existing row on a unique-key conflict (upsert).
  def supports_insert_on_duplicate_update? : Bool
    false
  end

  # DDL statements roll back with the surrounding transaction.
  def supports_ddl_transactions? : Bool
    false
  end

  # `CREATE INDEX ... WHERE condition`.
  def supports_partial_index? : Bool
    false
  end

  # Indexes over expressions such as `lower(email)`.
  def supports_expression_index? : Bool
    false
  end

  # `CHECK` constraints that the server enforces.
  def supports_check_constraints? : Bool
    false
  end

  # Foreign key constraints that the server can enforce.
  def supports_foreign_keys? : Bool
    false
  end

  def supports_views? : Bool
    false
  end

  # `datetime` columns with sub-second precision.
  def supports_datetime_with_precision? : Bool
    false
  end

  # A native JSON column type and JSON functions.
  def supports_json? : Bool
    false
  end

  # `WITH ... AS (...)` common table expressions.
  def supports_common_table_expressions? : Bool
    false
  end

  # Generated (computed) columns.
  def supports_virtual_columns? : Bool
    false
  end

  # `COMMENT` on tables and columns stored in the catalog.
  def supports_comments? : Bool
    false
  end

  # `EXPLAIN` of a statement.
  def supports_explain? : Bool
    false
  end

  # Inline optimizer hints such as `/*+ ... */`.
  def supports_optimizer_hints? : Bool
    false
  end

  # Server side advisory (application defined) locks.
  def supports_advisory_locks? : Bool
    false
  end

  # One non-blocking attempt to take the advisory lock *key* on *connection*
  # (the session that will keep it). `Grant::AdvisoryLock.synchronize` polls
  # this and pairs it with `#release_advisory_lock`.
  def try_advisory_lock(connection : DB::Connection, key : String) : Bool
    Grant::AdvisoryLock.try_acquire(self, connection, key)
  end

  # Releases *key* on the *connection* that took it.
  def release_advisory_lock(connection : DB::Connection, key : String) : Nil
    Grant::AdvisoryLock.release(self, connection, key)
  end

  # Several `ALTER TABLE` changes in one statement.
  def supports_bulk_alter? : Bool
    false
  end

  # More than one connection can use the database at once.
  def supports_concurrent_connections? : Bool
    false
  end

  # A transaction aborted by a deadlock or serialization failure can simply be
  # run again on a fresh transaction.
  def supports_restart_db_transaction? : Bool
    false
  end

  # Foreign key checks can be switched off temporarily, for fixtures and bulk loads.
  def supports_disable_referential_integrity? : Bool
    false
  end

  # `UNIQUE NULLS NOT DISTINCT`.
  def supports_nulls_not_distinct? : Bool
    false
  end

  # Methods for checking database capabilities
  abstract def supports_lock_mode?(mode : Grant::Locking::LockMode) : Bool
  abstract def supports_isolation_level?(level : Grant::Transaction::IsolationLevel) : Bool
  abstract def supports_savepoints? : Bool

  # Renders the SQL clause for a row-level lock *mode* (e.g. "FOR UPDATE").
  #
  # Defined here via virtual dispatch so `Grant::Locking::LockMode#to_sql`
  # does not need to `case` over concrete adapter class literals — that
  # would force every adapter (pg, mysql, sqlite) to compile even when an
  # app only requires one. Each adapter overrides this with its own SQL.
  #
  # The default raises, so an adapter that has not implemented locking
  # signals clearly rather than silently emitting wrong SQL.
  def lock_clause(mode : Grant::Locking::LockMode) : String
    raise "Adapter #{self.class} does not implement row-level locking"
  end

  # Returns the number of rows affected by *result* for an optimistic-lock
  # UPDATE, given the open connection *db*. Pg/MySQL report this directly
  # via `result.rows_affected`; SQLite overrides to query `changes()`.
  #
  # Defined via dispatch for the same reason as `#lock_clause` — to avoid
  # `case`ing over adapter class literals in `Grant::Locking::Optimistic`.
  # This base implementation returns `1` to preserve the prior `else 1_i64`
  # fallback for adapters (e.g. the test virtual-shard adapter) that don't
  # report affected rows. *db* is intentionally untyped because some
  # adapters yield themselves rather than a `DB::Connection` from `#open`.
  def rows_affected_for_optimistic_lock(db, result : DB::ExecResult) : Int64
    1_i64
  end

  # ---------------------------------------------------------------------------
  # Large-table / high-scale: index hints (virtual dispatch)
  # ---------------------------------------------------------------------------

  # Whether this adapter can render *any* index hint into its SQL. Used by the
  # safe-fallback machinery to decide whether to attempt a hint at all (vs.
  # degrade per `Grant.settings.index_hint_mode`). PG core has no planner-hint
  # syntax, so its adapter returns `false`.
  #
  # Defined here via virtual dispatch — like `#lock_clause` — so the hint
  # rendering does not `case` over concrete adapter class literals (which would
  # force every adapter to compile even when an app requires only one).
  def supports_index_hints? : Bool
    false
  end

  # Renders the SQL fragment that attaches an index hint to a table reference,
  # placed immediately after the table name in the FROM clause.
  #
  # *kind* is `:use`, `:force`, or `:ignore`; *index_names* are the bare index
  # identifiers. Returns `nil` when the adapter cannot honor this particular
  # hint kind (the caller then degrades per `index_hint_mode`).
  #
  # The base implementation returns `nil` (no hint). MySQL/SQLite override.
  def index_hint_clause(kind : Symbol, index_names : Array(String)) : String?
    nil
  end

  # Returns `true` when *error* is the adapter's "no such index" / unknown-key
  # error for an index hint, so the safe-fallback path can catch a bad hint and
  # re-run without it. Matched on message text because crystal-db surfaces these
  # as generic exceptions across drivers. Adapters may override for precision.
  def index_missing_error?(error : Exception) : Bool
    msg = error.message
    return false unless msg
    m = msg.downcase
    m.includes?("no such index") ||                           # SQLite
      m.includes?("can't find any index") ||                  # SQLite (older phrasing)
      (m.includes?("key") && m.includes?("doesn't exist")) || # MySQL: Key 'x' doesn't exist in table
      m.includes?("unknown key")
  end
end
