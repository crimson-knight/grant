require "db"
require "../grant/error_taxonomy"

# Shared vocabulary for turning driver failures into Grant's error taxonomy.
#
# Each adapter classifies its own driver error into a `Kind` from a machine
# readable code (a PostgreSQL SQLSTATE, a MySQL errno, an SQLite result code)
# and this module builds the matching `Grant::ErrorBase` subclass. Translation
# runs only inside a `rescue`, so the success path pays nothing.
module Grant::Adapter::ErrorTranslator
  # What went wrong, independent of the database that reported it.
  enum Kind
    Unique
    ForeignKey
    NotNull
    ValueTooLong
    Deadlock
    SerializationFailure
    LockWaitTimeout
    StatementTimeout
    QueryCanceled
    ReadOnly
    NoDatabase
  end

  # Classifies a PostgreSQL SQLSTATE, or returns nil for codes Grant does not
  # translate. See https://www.postgresql.org/docs/current/errcodes-appendix.html
  def self.kind_for_sqlstate(state : String) : Kind?
    case state
    when "23505" then Kind::Unique
    when "23503" then Kind::ForeignKey
    when "23502" then Kind::NotNull
    when "22001" then Kind::ValueTooLong
    when "40P01" then Kind::Deadlock
    when "40001" then Kind::SerializationFailure
    when "55P03" then Kind::LockWaitTimeout
    when "57014" then Kind::QueryCanceled
    when "25006" then Kind::ReadOnly
    when "3D000" then Kind::NoDatabase
    end
  end

  # Builds the taxonomy error for *kind*. The driver exception stays reachable
  # as `#cause`.
  def self.build(kind : Kind, message : String?, sql : String?, binds : Enumerable?, cause : ::Exception?) : Grant::ErrorBase
    case kind
    in .unique?                then Grant::RecordNotUnique.new(message, sql, binds, cause)
    in .foreign_key?           then Grant::InvalidForeignKey.new(message, sql, binds, cause)
    in .not_null?              then Grant::NotNullViolation.new(message, sql, binds, cause)
    in .value_too_long?        then Grant::ValueTooLong.new(message, sql, binds, cause)
    in .deadlock?              then Grant::Deadlocked.new(message, sql, binds, cause)
    in .serialization_failure? then Grant::SerializationFailure.new(message, sql, binds, cause)
    in .lock_wait_timeout?     then Grant::LockWaitTimeout.new(message, sql, binds, cause)
    in .statement_timeout?     then Grant::StatementTimeout.new(message, sql, binds, cause)
    in .query_canceled?        then Grant::QueryCanceled.new(message, sql, binds, cause)
    in .no_database?           then Grant::NoDatabaseError.new(message, sql, binds, cause)
    in .read_only?
      Grant::Transaction::ReadOnlyError.new(message || "Cannot modify data in read-only transaction")
    end
  end

  # Translates the connection failures crystal-db itself reports, which are the
  # same for every adapter. Returns nil for any other exception.
  def self.translate_pool_error(ex : ::Exception) : Grant::ErrorBase?
    if ex.is_a?(DB::PoolTimeout)
      Grant::ConnectionTimeoutError.new(ex.message || "Timed out waiting for a database connection", cause: ex)
    elsif ex.is_a?(DB::PoolResourceRefused) || ex.is_a?(DB::PoolResourceLost) || ex.is_a?(DB::PoolRetryAttemptsExceeded)
      Grant::ConnectionFailed.new(ex.message || "Could not connect to the database", cause: ex)
    end
  end
end
