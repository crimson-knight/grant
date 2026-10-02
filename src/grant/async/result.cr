require "./promise"
require "./errors"
require "./limiter"

module Grant
  module Async
    # Wrapper for async operation results
    class Result(T)
      getter promise : Promise(T)
      @fiber : Fiber?
      @completed : Atomic(Bool)
      @started_at : Time::Instant

      # Starts *block* on a new fiber. At most `Grant.settings.async_pool_size`
      # async blocks run at once; the rest wait for a slot. A result started
      # from inside another async fiber, and the chained results of `then`,
      # `map` and `flat_map` (*limited* false), take no slot, because they
      # wait on work that already holds one and could otherwise deadlock.
      def initialize(limited : Bool = true, &block : -> T)
        @completed = Atomic(Bool).new(false)
        @promise = Promise(T).new
        @started_at = Time.instant
        origin = Fiber.current
        limited = false if origin.grant_async_origin
        @fiber = spawn do
          Async::Metrics.track_operation do
            result = if limited
                       Limiter.current.run { Grant::Notifications.async_from(origin) { block.call } }
                     else
                       Grant::Notifications.async_from(origin) { block.call }
                     end
            @promise.resolve(result)
          end
        rescue e
          @promise.reject(e)
        ensure
          @completed.set(true)
        end
      end

      # Wait for the result
      def wait : T
        @promise.get
      end

      # Wait with timeout
      def wait_with_timeout(timeout : Time::Span) : T
        deadline = @started_at + timeout
        remaining = deadline - Time.instant

        if remaining <= Time::Span.zero
          raise AsyncTimeoutError.new("async operation", timeout)
        end

        select
        when result = @promise.get_channel.receive
          case result
          when Exception
            raise result
          else
            result.as(T)
          end
        when timeout(remaining)
          raise AsyncTimeoutError.new("async operation", timeout)
        end
      end

      # Check if completed
      def completed? : Bool
        @completed.get
      end

      # Error recovery
      def on_error(&block : Exception -> T) : T
        begin
          wait
        rescue e
          block.call(e)
        end
      end

      # Chain operations
      def then(&block : T -> U) : Result(U) forall U
        Result(U).new(limited: false) do
          value = wait
          block.call(value)
        end
      end

      # Map the result
      def map(&block : T -> U) : Result(U) forall U
        Result(U).new(limited: false) do
          value = wait
          block.call(value)
        end
      end

      # Flat map for chaining async operations
      def flat_map(&block : T -> Result(U)) : Result(U) forall U
        Result(U).new(limited: false) do
          value = wait
          block.call(value).wait
        end
      end
    end
  end
end
