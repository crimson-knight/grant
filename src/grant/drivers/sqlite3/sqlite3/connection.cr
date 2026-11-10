class Grant::SQLite3::Connection < DB::Connection
  @handle_closed = false

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

  def initialize(options : ::DB::Connection::Options, sqlite3_options : Options)
    super(options)
    check LibSQLite3.open_v2(sqlite3_options.filename, out @db, (Flag::READWRITE | Flag::CREATE), nil)
    # 2 means 2 arguments; 1 is the code for UTF-8
    check LibSQLite3.create_function(@db, "regexp", 2, 1, nil, SQLite3::REGEXP_FN, nil, nil)

    if pragma_statement = sqlite3_options.pragma_statement
      check LibSQLite3.exec(@db, pragma_statement, nil, nil, nil)
    end
  rescue
    raise DB::ConnectionRefused.new
  end

  def self.filename(uri : URI)
    URI.decode_www_form((uri.hostname || "") + uri.path)
  end

  def build_prepared_statement(query) : Statement
    Statement.new(self, query)
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
  # uncached statement is unfinalized. The connection then stays in its pool
  # and reports open, so a later `close` (or `Database#close`) retries. Once
  # the handle closes, the connection leaves its pool, is marked closed even
  # when a statement error is raised, and never passes the handle to SQLite
  # again.
  def do_close
    first_statement_error = nil
    @statements_cache.each_value do |statement|
      statement.close
    rescue error : Exception
      first_statement_error ||= error
    end
    @statements_cache.clear

    close_code = 0
    unless @handle_closed
      close_code = LibSQLite3.close(self)
      if close_code == 0
        @handle_closed = true
        context.discard self
      end
    end

    if first_statement_error
      @closed = true if @handle_closed
      raise first_statement_error
    end
    check close_code
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
    backup_item = LibSQLite3.backup_init(to.@db, "main", @db, "main")
    if backup_item.null?
      raise Exception.new(to.@db)
    end
    code = LibSQLite3.backup_step(backup_item, -1)

    if code != LibSQLite3::Code::DONE
      raise Exception.new(to.@db)
    end
    code = LibSQLite3.backup_finish(backup_item)
    if code != LibSQLite3::Code::OKAY
      raise Exception.new(to.@db)
    end
  end

  def to_unsafe
    @db
  end

  private def check(code)
    raise Exception.new(self) unless code == 0
  end
end
