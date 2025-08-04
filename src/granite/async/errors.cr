module Granite
  module Async
    # Base async error
    class AsyncError < Exception
    end
    
    # Error for async execution failures
    class AsyncExecutionError < AsyncError
      getter operation : String
      getter original_error : Exception
      
      def initialize(@operation : String, @original_error : Exception)
        super("Async operation '#{@operation}' failed: #{@original_error.message}")
      end
    end
    
    # Error for async timeouts
    class AsyncTimeoutError < AsyncError
      getter operation : String
      getter timeout : Time::Span
      
      def initialize(@operation : String, @timeout : Time::Span)
        super("Async operation '#{@operation}' timed out after #{@timeout}")
      end
    end
    
    # Error for async coordination failures
    class AsyncCoordinationError < AsyncError
      getter failed_operations : Array(String)
      
      def initialize(@failed_operations : Array(String))
        super("Async coordination failed for operations: #{@failed_operations.join(", ")}")
      end
    end
  end
end