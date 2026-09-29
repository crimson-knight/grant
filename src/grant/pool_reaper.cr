require "log"

module Grant
  # Keeps one adapter's pool from holding dead or unneeded connections.
  #
  # Every `reaping_frequency` it runs `#sweep`, which
  #
  # * closes idle connections, down to `min_connections`, once nothing has been
  #   checked out for `idle_timeout`,
  # * closes idle connections that have been open longer than `max_age`, and
  # * runs `SELECT 1` on the idle connections every `keepalive`, so a server or
  #   proxy that drops idle sockets is noticed before a request needs one.
  #
  # A sweep takes each connection out of the pool before doing any I/O on it,
  # so it never holds the pool's mutex while talking to the database. Sweeps run
  # on a slow timer; the defaults apply no reaping at all.
  class PoolReaper
    Log = ::Log.for("grant.pool_reaper")

    @running : Atomic(Bool) = Atomic(Bool).new(false)
    @stop_signal = Channel(Nil).new(1)
    @last_keepalive_ticks : Int64 = Grant::Adapter::PoolSupport.ticks

    def initialize(@adapter : Grant::Adapter::Base, @frequency : Time::Span)
    end

    # Starts the sweep timer in its own fiber.
    def start : Nil
      return if @running.swap(true)

      spawn do
        loop do
          select
          when @stop_signal.receive
            break
          when timeout(@frequency)
            break unless @running.get
            begin
              sweep
            rescue ex
              Log.warn(exception: ex) { "Pool sweep failed for #{@adapter.name}" }
            end
          end
        end
      end
    end

    # Stops the timer fiber.
    def stop : Nil
      return unless @running.swap(false)

      select
      when @stop_signal.send(nil)
      else
      end
    end

    # Runs one sweep now and returns how many idle connections it closed.
    def sweep : Int32
      closed = 0
      now = Grant::Adapter::PoolSupport.ticks

      if idle_timeout = @adapter.idle_timeout
        if now - @adapter.last_used_ticks >= idle_timeout.total_milliseconds
          closed = @adapter.close_idle_connections(keep: @adapter.min_connections)
          Log.debug { "Closed #{closed} idle connection(s) on #{@adapter.name}" } if closed > 0
        end
      end

      closed += @adapter.close_aged_connections

      if keepalive = @adapter.keepalive
        if now - @last_keepalive_ticks >= keepalive.total_milliseconds
          @last_keepalive_ticks = now
          @adapter.keepalive_idle_connections
        end
      end

      closed
    end
  end
end
