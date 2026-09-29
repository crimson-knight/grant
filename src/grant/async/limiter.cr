module Grant
  module Async
    # Counting semaphore that caps how many async queries run at once. Each
    # running query holds a pool connection, so the cap (see
    # `Grant.settings.async_pool_size`) keeps `load_async` from starving the
    # pool. Waiting fibers park on a channel and cost nothing while they wait.
    class Limiter
      getter size : Int32
      @slots : Channel(Nil)

      def initialize(@size : Int32)
        @slots = Channel(Nil).new(@size)
      end

      # The limiter for the current `async_pool_size`. Changing the setting
      # starts a new limiter; queries already running finish on the old one.
      def self.current : Limiter
        size = Grant.settings.async_pool_size
        limiter = @@current
        return limiter if limiter && limiter.size == size

        @@current = new(size)
      end

      @@current : Limiter?

      # Blocks until a slot is free, runs *block*, and frees the slot.
      def run(& : -> T) : T forall T
        @slots.send(nil)
        begin
          yield
        ensure
          @slots.receive
        end
      end
    end
  end
end
