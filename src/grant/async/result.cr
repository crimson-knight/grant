require "./promise"
require "./errors"

module Grant
  module Async
    # Wrapper for async operation results
    class Result(T)
      getter promise : Promise(T)
      @fiber : Fiber?
      @completed : Atomic(Bool)
      @started_at : Time::Span
      
      def initialize(&block : -> T)
        @completed = Atomic(Bool).new(false)
        @promise = Promise(T).new
        @started_at = Time.monotonic
        @fiber = spawn do
          begin
            Async::Metrics.track_operation do
              result = block.call
              @promise.resolve(result)
            end
          rescue e
            @promise.reject(e)
          ensure
            @completed.set(true)
          end
        end
      end
      
      # Wait for the result
      def wait : T
        @promise.get
      end
      
      # Wait with timeout
      def wait_with_timeout(timeout : Time::Span) : T
        deadline = @started_at + timeout
        remaining = deadline - Time.monotonic
        
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
        Result(U).new do
          value = wait
          block.call(value)
        end
      end
      
      # Map the result
      def map(&block : T -> U) : Result(U) forall U
        Result(U).new do
          value = wait
          block.call(value)
        end
      end
      
      # Flat map for chaining async operations
      def flat_map(&block : T -> Result(U)) : Result(U) forall U
        Result(U).new do
          value = wait
          block.call(value).wait
        end
      end
    end
  end
end