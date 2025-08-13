module Grant
  module Async
    # Metrics tracking for async operations
    class Metrics
      class_property total_operations = Atomic(Int64).new(0)
      class_property active_operations = Atomic(Int64).new(0)
      class_property failed_operations = Atomic(Int64).new(0)
      class_property total_duration = Atomic(Int64).new(0) # in microseconds
      
      # Track an operation
      def self.track_operation(&block)
        active_operations.add(1)
        total_operations.add(1)
        start_time = Time.monotonic
        
        begin
          yield
        rescue e
          failed_operations.add(1)
          raise e
        ensure
          duration = Time.monotonic - start_time
          total_duration.add(duration.total_microseconds.to_i64)
          active_operations.sub(1)
        end
      end
      
      # Get current metrics
      def self.snapshot : NamedTuple
        {
          total: total_operations.get,
          active: active_operations.get,
          failed: failed_operations.get,
          success_rate: calculate_success_rate,
          avg_duration_ms: calculate_avg_duration_ms
        }
      end
      
      # Reset all metrics
      def self.reset
        total_operations.set(0)
        active_operations.set(0)
        failed_operations.set(0)
        total_duration.set(0)
      end
      
      private def self.calculate_success_rate : Float64
        total = total_operations.get
        return 0.0 if total == 0
        
        failed = failed_operations.get
        ((total - failed) * 100.0) / total
      end
      
      private def self.calculate_avg_duration_ms : Float64
        total = total_operations.get
        return 0.0 if total == 0
        
        duration_us = total_duration.get
        (duration_us / total) / 1000.0
      end
    end
  end
end