require "digest/md5"
require "./error_taxonomy"

module Grant
  # Raised when an advisory lock is still held by someone else after the
  # timeout.
  class AdvisoryLockTimeout < ErrorBase
    getter key : String

    def initialize(@key : String, timeout : Time::Span)
      super("Could not take advisory lock #{@key.inspect} within #{timeout}; another process holds it")
    end
  end

  # Raised when the adapter has no advisory lock.
  class AdvisoryLockUnsupported < ErrorBase
  end

  # Named, application-defined locks held in the database server (PostgreSQL
  # `pg_advisory_lock`, MySQL `GET_LOCK`) or, for SQLite, in a lock file
  # beside the database (process-local for an in-memory database).
  #
  # A server lock belongs to one database session, so it is taken and released
  # on the same checked-out connection (`Adapter::Base#with_connection`), and
  # every statement the block issues runs on that connection too. The lock is
  # released in `ensure`; if the connection dies first the server drops it, and
  # SQLite's file lock goes with the process.
  #
  # ```
  # Grant.with_advisory_lock("nightly-import", timeout: 30.seconds) do
  #   # only one process at a time gets here
  # end
  # ```
  #
  # Acquisition polls `try` every 25 ms instead of blocking in the server, so a
  # waiting fiber never parks a connection inside a blocking call.
  module AdvisoryLock
    Log           = ::Log.for("grant.advisory_lock")
    POLL_INTERVAL = 25.milliseconds

    private class SqliteHold
      getter owner : Fiber
      getter file : File?
      property count : Int32 = 1

      def initialize(@owner : Fiber, @file : File?)
      end
    end

    @@sqlite_holds = {} of String => SqliteHold
    @@sqlite_mutex = Mutex.new

    # Runs the block holding lock *key* on *adapter*, waiting up to *timeout*
    # for it. Raises `AdvisoryLockTimeout` when it cannot be taken.
    def self.synchronize(adapter : Grant::Adapter::Base, key : String, timeout : Time::Span = 5.seconds, & : -> T) : T forall T
      raise AdvisoryLockUnsupported.new("The #{adapter.adapter_name} adapter has no advisory locks") unless adapter.supports_advisory_locks? || adapter.sqlite?
      adapter.with_connection do |connection|
        acquire(adapter, connection, key, timeout)
        begin
          yield
        ensure
          begin
            adapter.release_advisory_lock(connection, key)
          rescue ex : DB::Error
            Log.warn(exception: ex) { "Could not release advisory lock #{key.inspect}; the server drops it with the session" }
          end
        end
      end
    end

    # Polls `Adapter::Base#try_advisory_lock` until *timeout* runs out.
    def self.acquire(adapter : Grant::Adapter::Base, connection : DB::Connection, key : String, timeout : Time::Span) : Nil
      deadline = Time.instant + timeout
      loop do
        return if adapter.try_advisory_lock(connection, key)
        raise AdvisoryLockTimeout.new(key, timeout) if Time.instant >= deadline
        sleep POLL_INTERVAL
      end
    end

    # The 64-bit integer PostgreSQL takes for *key*: the first eight bytes of
    # its MD5, stable across processes and versions.
    def self.key_to_int64(key : String) : Int64
      IO::ByteFormat::BigEndian.decode(Int64, Digest::MD5.digest(key)[0, 8])
    end

    # The name MySQL `GET_LOCK` takes (64 characters at most).
    def self.mysql_name(key : String) : String
      name = "grant:#{key}"
      name.bytesize <= 64 ? name : "grant:#{Digest::MD5.hexdigest(key)}"
    end

    # One attempt to take *key*; `Adapter::Base#try_advisory_lock` calls this.
    def self.try_acquire(adapter : Grant::Adapter::Base, connection : DB::Connection, key : String) : Bool
      if adapter.postgres?
        connection.scalar("SELECT pg_try_advisory_lock($1)", key_to_int64(key)).as(Bool)
      elsif adapter.mysql?
        connection.scalar("SELECT GET_LOCK(?, 0)", mysql_name(key)).as?(Int).try(&.== 1) || false
      elsif adapter.sqlite?
        sqlite_try(adapter, key)
      else
        raise AdvisoryLockUnsupported.new("The #{adapter.adapter_name} adapter has no advisory locks")
      end
    end

    def self.release(adapter : Grant::Adapter::Base, connection : DB::Connection, key : String) : Nil
      if adapter.postgres?
        connection.scalar("SELECT pg_advisory_unlock($1)", key_to_int64(key))
      elsif adapter.mysql?
        connection.scalar("SELECT RELEASE_LOCK(?)", mysql_name(key))
      elsif adapter.sqlite?
        sqlite_release(adapter, key)
      end
    end

    # SQLite cannot hold a lock in a session without blocking its own DDL
    # (`BEGIN EXCLUSIVE` would also lock out the connection that runs the
    # migration and forbids the table rebuilds `change_column` needs), so the
    # lock is an `flock` on a file next to the database. The kernel drops it
    # when the process dies. Inside one process the hold table makes a second
    # fiber wait and lets the holding fiber re-enter.
    private def self.sqlite_try(adapter : Grant::Adapter::Base, key : String) : Bool
      id = sqlite_id(adapter, key)
      @@sqlite_mutex.synchronize do
        if hold = @@sqlite_holds[id]?
          return false unless hold.owner == Fiber.current
          hold.count += 1
          return true
        end
        path = sqlite_lock_path(adapter, key)
        file = nil.as(File?)
        if path
          file = File.open(path, "a")
          begin
            file.flock_exclusive(blocking: false)
          rescue IO::Error
            file.close
            return false
          end
        end
        @@sqlite_holds[id] = SqliteHold.new(Fiber.current, file)
        true
      end
    end

    private def self.sqlite_release(adapter : Grant::Adapter::Base, key : String) : Nil
      id = sqlite_id(adapter, key)
      @@sqlite_mutex.synchronize do
        hold = @@sqlite_holds[id]? || return
        hold.count -= 1
        return if hold.count > 0
        @@sqlite_holds.delete(id)
        if file = hold.file
          file.flock_unlock
          file.close
        end
      end
    end

    private def self.sqlite_id(adapter : Grant::Adapter::Base, key : String) : String
      "#{sqlite_database_file(adapter) || adapter.object_id}\0#{key}"
    end

    private def self.sqlite_lock_path(adapter : Grant::Adapter::Base, key : String) : String?
      file = sqlite_database_file(adapter) || return nil
      "#{file}.grant-lock-#{Digest::MD5.hexdigest(key)[0, 12]}"
    end

    # The database file, or nil for an in-memory database.
    private def self.sqlite_database_file(adapter : Grant::Adapter::Base) : String?
      database = adapter.current_database
      database == ":memory:" ? nil : database
    end
  end

  # Runs the block holding the advisory lock *key* on *adapter* (the default
  # database when omitted). See `Grant::AdvisoryLock`.
  def self.with_advisory_lock(key : String, adapter : Grant::Adapter::Base? = nil, timeout : Time::Span = 5.seconds, & : -> T) : T forall T
    AdvisoryLock.synchronize(adapter || ConnectionRegistry.get_adapter(ConnectionRegistry.default_database), key, timeout) { yield }
  end
end
