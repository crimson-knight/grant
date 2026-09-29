# Query cache: memoizes the result of identical read statements inside a
# `Grant.cache { ... }` block (or one HTTP request, with
# `Grant::Middleware::QueryCache`), like ActiveRecord's query cache.
#
# ```
# Grant.cache do
#   User.where(active: true).to_a # runs SQL
#   User.where(active: true).to_a # answered from the cache
#   User.create(name: "Ada")      # any write clears the cache
#   User.where(active: true).to_a # runs SQL again
#   Grant.uncached { User.count } # always runs SQL
# end
# ```
#
# The cache lives on the fiber that opened the block, so reading it takes no
# lock. Entries are keyed on the SQL text, its bind values and the connection
# the statement would run on (a transaction or pinned connection keeps its own
# entries, since it sees its own uncommitted writes). It holds at most
# `Grant.settings.query_cache_max_entries` statements and evicts the least
# recently used.
#
# Every write, DDL statement or transaction end, from any fiber and any
# connection, bumps one process-wide atomic counter; a cache that sees the
# counter move drops all its entries before answering. Reads only load the
# counter. A result that was read while a write finished is not stored.
#
# Records returned from the cache are copies (`clone`), so changing one never
# alters what the next read returns.
module Grant::QueryCache
  @@generation = Atomic(UInt64).new(0_u64)

  # Reads that hold row locks must reach the database every time.
  LOCKING_READ = /\bfor\s+(update|share|no\s+key\s+update|key\s+share)\b/i

  alias Key = {UInt64, UInt64, String, Array(Grant::Columns::Type)}

  # :nodoc:
  abstract class Slot
  end

  # :nodoc:
  class ValueSlot(T) < Slot
    getter value : T

    def initialize(@value : T)
    end
  end

  # The cache of one fiber: its entries, whether it is currently answering
  # reads, and the write counter it was last valid for.
  class State
    getter entries = {} of Key => Slot
    property? enabled : Bool = true
    property generation : UInt64
    getter hits : Int64 = 0_i64
    getter misses : Int64 = 0_i64

    def initialize(@generation : UInt64)
    end

    # Drops every entry.
    def clear : Nil
      @entries.clear
    end

    def size : Int32
      @entries.size
    end

    # :nodoc:
    def record_hit : Nil
      @hits += 1
    end

    # :nodoc:
    def record_miss : Nil
      @misses += 1
    end
  end

  # Marks that data may have changed; every fiber's cache empties on its next
  # read. Called by the adapter around each statement that is not a plain read
  # and whenever a transaction begins, commits or rolls back.
  def self.invalidate! : Nil
    @@generation.add(1_u64)
  end

  # The number of times `invalidate!` ran; a cache entry is only trusted while
  # this is unchanged.
  def self.generation : UInt64
    @@generation.get
  end

  # The current fiber's cache, or `nil` outside a `cache` block.
  def self.current? : State?
    Fiber.current.grant_query_cache
  end

  # True inside a `cache` block that is not shadowed by `uncached`.
  def self.enabled? : Bool
    current?.try(&.enabled?) || false
  end

  # Runs *block* with the query cache on for the current fiber and returns its
  # value. Nested calls share one cache; the outermost call discards it when the
  # block ends, also when it raises.
  def self.cache(& : -> T) : T forall T
    fiber = Fiber.current
    existing = fiber.grant_query_cache
    state = existing || State.new(generation)
    fiber.grant_query_cache = state
    was_enabled = state.enabled?
    state.enabled = true
    begin
      yield
    ensure
      state.enabled = was_enabled
      if existing.nil?
        fiber.grant_query_cache = nil
        state.clear
      end
    end
  end

  # Runs *block* with the query cache off for the current fiber. Reads inside
  # neither use nor fill the cache; writes still clear it.
  def self.uncached(& : -> T) : T forall T
    state = current?
    return yield unless state

    was_enabled = state.enabled?
    state.enabled = false
    begin
      yield
    ensure
      state.enabled = was_enabled
    end
  end

  # Returns the memoized result of the read *sql* with *binds* on *adapter*, or
  # runs *block* and remembers what it returns. Does nothing but run *block*
  # when no cache is active, *sql* is not a plain read, or it takes row locks.
  #
  # *copy* turns a stored value into a private copy; give it for values a
  # caller can mutate (arrays, records).
  def self.fetch(adapter : Grant::Adapter::Base, sql : String, binds : Array(Grant::Columns::Type),
                 name : String?, copy : (T -> T)? = nil, & : -> T) : T forall T
    state = Fiber.current.grant_query_cache
    return yield unless state && state.enabled?
    return yield unless Grant::Adapter::PoolSupport.idempotent_read?(sql) && !LOCKING_READ.matches?(sql)

    started = generation
    if state.generation != started
      state.clear
      state.generation = started
    end

    key = {adapter.object_id, connection_id(adapter), sql, binds}
    if slot = state.entries.delete(key)
      if typed = slot.as?(ValueSlot(T))
        state.entries[key] = slot
        state.record_hit
        Grant::Notifications.publish_sql(adapter, sql, binds, Time::Span.zero, name, cached: true)
        stored = typed.value
        return copy ? copy.call(stored) : stored
      end
    end

    state.record_miss
    result = yield
    # A write that finished while the read ran may make the rows stale.
    if generation == started && state.enabled?
      max = Grant.settings.query_cache_max_entries
      if max > 0
        while state.entries.size >= max
          state.entries.shift?
        end
        state.entries[{key[0], key[1], key[2], key[3].dup}] = ValueSlot(T).new(copy ? copy.call(result) : result)
      end
    end
    result
  end

  private def self.connection_id(adapter : Grant::Adapter::Base) : UInt64
    connection = Grant::SchemaTenant.current_connection?(adapter) ||
                 Grant::Transaction.current_connection?(adapter) ||
                 adapter.pinned_connection?
    connection ? connection.object_id : 0_u64
  end

  # Class-level `Model.cache { }` and `Model.uncached { }`, as in ActiveRecord.
  module ClassMethods
    def cache(& : -> T) : T forall T
      Grant::QueryCache.cache { yield }
    end

    def uncached(& : -> T) : T forall T
      Grant::QueryCache.uncached { yield }
    end

    # True while a query cache answers this fiber's reads.
    def query_cache_enabled? : Bool
      Grant::QueryCache.enabled?
    end
  end
end

class Fiber
  # Fiber-local slot for `Grant::QueryCache::State`.
  # :nodoc:
  property grant_query_cache : Grant::QueryCache::State?
end

module Grant
  # Runs *block* with the query cache on; see `Grant::QueryCache`.
  def self.cache(& : -> T) : T forall T
    QueryCache.cache { yield }
  end

  # Runs *block* with the query cache off.
  def self.uncached(& : -> T) : T forall T
    QueryCache.uncached { yield }
  end
end
