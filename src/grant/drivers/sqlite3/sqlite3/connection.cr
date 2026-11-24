class Grant::SQLite3::Connection < DB::Connection
  @handle_closed = false
  @statement_error_awaiting_close : ::Exception? = nil

  record Options,
    filename : String = ":memory:",
    # pragmas
    busy_timeout : String? = nil,
    cache_size : String? = nil,
    foreign_keys : String? = nil,
    journal_mode : String? = nil,
    synchronous : String? = nil,
    wal_autocheckpoint : String? = nil do
    def self.from_uri(uri : URI, default = Options.new)
      params = HTTP::Params.parse(uri.query || "")

      Options.new(
        filename: URI.decode_www_form((uri.hostname || "") + uri.path),
        # pragmas
        busy_timeout: params.fetch("busy_timeout", default.busy_timeout),
        cache_size: params.fetch("cache_size", default.cache_size),
        foreign_keys: params.fetch("foreign_keys", default.foreign_keys),
        journal_mode: params.fetch("journal_mode", default.journal_mode),
        synchronous: params.fetch("synchronous", default.synchronous),
        wal_autocheckpoint: params.fetch("wal_autocheckpoint", default.wal_autocheckpoint),
      )
    end

    def pragma_statement
      res = String.build do |str|
        pragma_append(str, "busy_timeout", busy_timeout)
        pragma_append(str, "cache_size", cache_size)
        pragma_append(str, "foreign_keys", foreign_keys)
        pragma_append(str, "journal_mode", journal_mode)
        pragma_append(str, "synchronous", synchronous)
        pragma_append(str, "wal_autocheckpoint", wal_autocheckpoint)
      end

      res.empty? ? nil : res
    end

    private def pragma_append(io, key, value)
      return unless value
      io << "PRAGMA #{key}=#{value};"
    end
  end

  # :nodoc:
  #
  # The open database of the engine `Grant.settings.sqlite_engine` named
  # when this connection opened.
  getter engine_database : Engine::Database

  def initialize(options : ::DB::Connection::Options, sqlite3_options : Options)
    super(options)
    @engine_database = Connection.open_engine_database(sqlite3_options)
  end

  # :nodoc:
  #
  # Opens *sqlite3_options*' file with the selected engine, registers the
  # `REGEXP` function when the app requires it, and runs the URL's PRAGMA
  # string. Any failure refuses the connection.
  def self.open_engine_database(sqlite3_options : Options) : Engine::Database
    open_code, engine_database = Engine.selected.open(sqlite3_options.filename)
    check(engine_database, open_code)
    # The `REGEXP` SQL function is opt-in: `require "grant/regex"` defines
    # `RegexpFunction`, and only then does every connection register it.
    {% if Grant::SQLite3.has_constant?(:RegexpFunction) %}
      # A typed proc, so every engine's create_function sees the same
      # Engine::UserFunction (a block literal is typed by its body).
      regexp_function = Engine::UserFunction.new { |arguments| SQLite3::RegexpFunction.call(arguments) }
      check(engine_database, engine_database.create_function("regexp", SQLite3::RegexpFunction::ARGUMENT_COUNT, &regexp_function))
    {% end %}

    if pragma_statement = sqlite3_options.pragma_statement
      check(engine_database, engine_database.exec(pragma_statement))
    end
    engine_database
  rescue
    raise DB::ConnectionRefused.new
  end

  private def self.check(engine_database : Engine::Database, code : Int32) : Nil
    raise Exception.new(engine_database) unless code == Engine::OK_CODE
  end

  def self.filename(uri : URI)
    URI.decode_www_form((uri.hostname || "") + uri.path)
  end

  def build_prepared_statement(query) : Statement
    Statement.new(self, query)
  end

  # :nodoc:
  #
  # Writes *query* to `Grant.settings.sqlite_statement_capture`, when it is
  # set, as one line: a newline inside the statement becomes a space, as in
  # the committed corpus `spec/grant/sqlite_engine/corpus/grant_sql_corpus.txt`.
  def capture_prepared_statement(query : String) : Nil
    {% if Grant.has_constant?(:Settings) %}
      if capture = Grant.settings.sqlite_statement_capture
        capture.print(query.gsub('\n', ' ') + '\n')
      end
    {% end %}
  end

  def build_unprepared_statement(query) : Statement
    # sqlite3 does not support unprepared statement.
    # All statements once prepared should be released
    # when unneeded. Unprepared statement are not aim
    # to leave state in the connection. Mimicking them
    # with prepared statement would be wrong with
    # respect connection resources.
    raise DB::Error.new("SQLite3 driver does not support unprepared statements")
  end

  # Closes every cached statement, then the SQLite handle, and raises the
  # first error a statement reported while closing; raising at the first
  # statement would leave the rest of them and the handle open.
  #
  # sqlite3_close returns SQLITE_BUSY and keeps the handle open while an
  # uncached statement is unfinalized. Then the close failure is raised, so
  # the caller knows the connection is still open; the connection stays in
  # its pool and reports open, and any statement error waits for the close
  # that succeeds. Once the handle closes, the connection leaves its pool,
  # is marked closed even when a statement error is raised, and never passes
  # the handle to SQLite again.
  def do_close
    first_statement_error = @statement_error_awaiting_close
    @statement_error_awaiting_close = nil
    @statements_cache.each_value do |statement|
      statement.close
    rescue error : Exception
      first_statement_error ||= error
    end
    @statements_cache.clear

    unless @handle_closed
      close_code = @engine_database.close
      unless close_code == 0
        @statement_error_awaiting_close = first_statement_error
        raise Exception.new(self)
      end
      @handle_closed = true
      context.discard self
    end

    if first_statement_error
      @closed = true
      raise first_statement_error
    end
  end

  # :nodoc:
  def perform_begin_transaction
    self.prepared.exec "BEGIN"
  end

  # :nodoc:
  def perform_commit_transaction
    self.prepared.exec "COMMIT"
  end

  # :nodoc:
  def perform_rollback_transaction
    self.prepared.exec "ROLLBACK"
  end

  # :nodoc:
  def perform_create_savepoint(name)
    self.prepared.exec "SAVEPOINT #{name}"
  end

  # :nodoc:
  def perform_release_savepoint(name)
    self.prepared.exec "RELEASE SAVEPOINT #{name}"
  end

  # :nodoc:
  def perform_rollback_savepoint(name)
    self.prepared.exec "ROLLBACK TO #{name}"
  end

  # Dump the database to another SQLite3 database. This can be used for backing up a SQLite3 Database
  # to disk or the opposite
  def dump(to : SQLite3::Connection)
    unless @engine_database.backup_to(to.engine_database) == Engine::OK_CODE
      raise Exception.new(to)
    end
  end

  private def check(code)
    raise Exception.new(self) unless code == 0
  end
end
