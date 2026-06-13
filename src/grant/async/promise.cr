module Grant
  module Async
    # A simple promise implementation for async results
    class Promise(T)
      @channel : Channel(T | Exception)
      @resolved : Atomic(Bool)
      # Cached settled message so `get` is idempotent: the channel only ever
      # carries a single message (capacity 1), so the first `get` receives it
      # and stores it here; later calls (and concurrent waiters) read the cache
      # instead of blocking forever on an empty channel. Stored as the raw
      # `T | Exception` so the value/error branch narrowing in `get` matches the
      # original implementation (which is also what makes `Promise(NoReturn)`,
      # used for always-raising async blocks, type-check).
      @settled : Atomic(Bool)
      @result : (T | Exception)?
      @mutex : Mutex

      def initialize
        @channel = Channel(T | Exception).new(1)
        @resolved = Atomic(Bool).new(false)
        @settled = Atomic(Bool).new(false)
        @result = nil
        @mutex = Mutex.new
      end

      # Resolve the promise with a value
      def resolve(value : T)
        return if @resolved.get
        @resolved.set(true)
        @channel.send(value)
      end

      # Reject the promise with an error
      def reject(error : Exception)
        return if @resolved.get
        @resolved.set(true)
        @channel.send(error)
      end

      # Get the result (blocks until resolved). Idempotent — safe to call
      # multiple times and from multiple fibers (e.g. a Coordinator waiter plus
      # the caller that wants the value back).
      def get : T
        result = settled_result
        case result
        when Exception
          raise result
        else
          result.as(T)
        end
      end

      # Receives the single channel message exactly once, caches it, and
      # returns it on every call. The mutex serializes the first-receive so two
      # waiters can't both block on an already-drained channel.
      private def settled_result : T | Exception
        if @settled.get
          return @result.as(T | Exception)
        end

        @mutex.synchronize do
          unless @settled.get
            @result = @channel.receive
            @settled.set(true)
          end
        end

        @result.as(T | Exception)
      end

      # Get the channel for select operations
      def get_channel : Channel(T | Exception)
        @channel
      end

      # Check if promise is resolved
      def resolved? : Bool
        @resolved.get
      end
    end
  end
end
