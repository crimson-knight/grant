module Granite
  module Async
    # A simple promise implementation for async results
    class Promise(T)
      @channel : Channel(T | Exception)
      @resolved : Atomic(Bool)
      
      def initialize
        @channel = Channel(T | Exception).new(1)
        @resolved = Atomic(Bool).new(false)
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
      
      # Get the result (blocks until resolved)
      def get : T
        result = @channel.receive
        case result
        when Exception
          raise result
        else
          result.as(T)
        end
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