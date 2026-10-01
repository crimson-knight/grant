require "db"

module Grant
  # A point-in-time view of one connection pool, read without locking the
  # connection registry or the pool.
  #
  # `size` is the pool's maximum (0 means unlimited), `connections` the open
  # connections, `busy` those checked out, `idle` those available, and
  # `waiting` the fibers currently blocked in a checkout.
  #
  # Mirrors ActiveRecord's `connection_pool.stat`.
  record PoolStat,
    size : Int32,
    connections : Int32,
    busy : Int32,
    idle : Int32,
    waiting : Int32,
    in_flight : Int32 do
    # True when every connection the pool may open is checked out.
    def exhausted? : Bool
      size > 0 && idle == 0 && connections >= size
    end
  end

  module Adapter
    # Rules for when Grant may run a database call a second time.
    module PoolSupport
      # The longest pause between two attempts, so a pool stampede backs off
      # without ever sleeping for long.
      MAX_BACKOFF = 5.seconds

      private START = Time.instant

      # Milliseconds since the process started, on the monotonic clock. Cheap to
      # store in an atomic and immune to wall-clock changes.
      def self.ticks : Int64
        (Time.instant - START).total_milliseconds.to_i64
      end

      # True when *sql* is a plain read that is safe to run again after the
      # connection dropped: `SELECT`, `SHOW`, `EXPLAIN` (but not
      # `EXPLAIN ANALYZE`), or `VALUES`. A `WITH` statement can hide a write,
      # so it never counts. A call without SQL is never retried.
      def self.idempotent_read?(sql : String?) : Bool
        return false unless sql

        start = 0
        while start < sql.bytesize && sql.byte_at(start).chr.ascii_whitespace?
          start += 1
        end
        return false if start >= sql.bytesize

        head = sql.byte_slice(start, Math.min(16, sql.bytesize - start)).downcase
        if head.starts_with?("select") || head.starts_with?("show") || head.starts_with?("values")
          true
        elsif head.starts_with?("explain")
          !sql.byte_slice(start, Math.min(40, sql.bytesize - start)).downcase.includes?("analyze")
        else
          false
        end
      end

      # The pause before retry number *attempt* (0-based): *base* doubled per
      # attempt, capped at `MAX_BACKOFF`.
      def self.backoff(base : Time::Span, attempt : Int32) : Time::Span
        factor = 1_i64 << Math.min(attempt, 16)
        delay = base * factor
        delay > MAX_BACKOFF ? MAX_BACKOFF : delay
      end
    end
  end
end

# crystal-db keeps every prepared statement of a connection in an unbounded
# hash. Grant bounds it with `statement_limit`: once the cache holds that many
# statements the least recently used one is closed and dropped. A limit of 0
# (the default for a bare crystal-db connection) leaves the cache unbounded.
#
# Eviction is least recently used, not oldest inserted, because a statement
# can still be stepping a result set while its connection prepares others (a
# query issued per row inside a transaction). Closing that statement would
# finalize it under the open result set; recency keeps the statement in use
# at the young end of the cache.
#
# This reopens two crystal-db types on purpose; when the db shard is upgraded,
# compare `DB::StringKeyCache` and `DB::Connection#fetch_or_build_prepared_statement`.
class DB::StringKeyCache(T)
  # Maximum number of cached values; 0 means unbounded.
  property limit : Int32 = 0

  # Number of cached values.
  def size : Int32
    @cache.size
  end

  def fetch(key : String, &) : T
    limit = @limit
    value = @cache.fetch(key, nil)
    if value
      # A bounded cache keeps insertion order as recency order: move a hit to
      # the young end so eviction takes the least recently used statement.
      if limit > 0
        @cache.delete(key)
        @cache[key] = value
      end
      return value
    end

    value = yield
    if limit > 0
      while @cache.size >= limit
        oldest_key = @cache.first_key
        evicted = @cache.delete(oldest_key)
        evicted.close if evicted.responds_to?(:close)
      end
    end
    @cache[key] = value
  end
end

abstract class DB::Connection
  # When this connection was opened, on `Grant::Adapter::PoolSupport.ticks`.
  # :nodoc:
  getter grant_opened_ticks : Int64 = Grant::Adapter::PoolSupport.ticks

  # When this connection was last returned to the pool (or opened), on
  # `Grant::Adapter::PoolSupport.ticks`. The adapter compares it with
  # `verify_idle_after` at checkout.
  # :nodoc:
  property grant_last_used_ticks : Int64 = Grant::Adapter::PoolSupport.ticks

  # Bounds this connection's prepared statement cache; 0 means unbounded.
  def statement_cache_limit=(limit : Int32) : Int32
    @statements_cache.limit = limit
  end

  # Number of prepared statements currently cached on this connection.
  def statement_cache_size : Int32
    @statements_cache.size
  end
end

class Fiber
  # Fiber-local map of the connections `Adapter#with_connection` pinned, keyed
  # by adapter object id.
  # :nodoc:
  property grant_pinned_connections : Hash(UInt64, DB::Connection)?
end
