module Grant
  # A handle on the connection pool behind one adapter, for inspecting it and
  # managing its lifecycle: `Model.connection_pool` returns one.
  #
  # ```
  # pool = User.connection_pool
  # pool.stat        # => Grant::PoolStat(size: 25, connections: 3, busy: 1, idle: 2, ...)
  # pool.disconnect! # closes every connection; the pool reopens on next use
  # ```
  #
  # Mirrors ActiveRecord's `ConnectionAdapters::ConnectionPool`.
  class ConnectionPool
    getter adapter : Grant::Adapter::Base

    def initialize(@adapter : Grant::Adapter::Base)
    end

    # The pool's size, open, busy, idle and waiting connection counts. It reads
    # atomics and the pool's own counters, and takes no lock.
    def stat : Grant::PoolStat
      @adapter.pool_stat
    end

    # The most connections the pool opens; 0 means unlimited.
    def size : Int32
      stat.size
    end

    # Connections currently open, idle or not.
    def connections : Int32
      stat.connections
    end

    # Connections checked out right now.
    def busy : Int32
      stat.busy
    end

    # Connections open and available.
    def idle : Int32
      stat.idle
    end

    # Fibers blocked waiting for a connection.
    def waiting : Int32
      stat.waiting
    end

    # True once the pool has opened and until `#disconnect!` closes it.
    def connected? : Bool
      @adapter.connected?
    end

    # True when the server answers `SELECT 1`.
    def active? : Bool
      @adapter.active?
    end

    # Raises `Grant::ConnectionFailed` unless the server answers `SELECT 1`.
    def verify! : Nil
      @adapter.verify!
    end

    # Closes every connection. The pool opens a new one on next use.
    def disconnect! : Nil
      @adapter.disconnect!
    end

    # Replaces the pool with a fresh one and checks it can reach the server.
    def reconnect! : Nil
      @adapter.reconnect!
    end

    # Closes idle connections while more than *keep_open* connections remain
    # open, and returns how many it closed. Connections in use are left alone.
    def flush!(keep_open : Int32 = 0) : Int32
      @adapter.close_idle_connections(keep: keep_open)
    end

    # Yields one raw connection and pins it to this fiber for the block.
    def with_connection(& : DB::Connection -> T) : T forall T
      @adapter.with_connection { |connection| yield connection }
    end
  end
end
