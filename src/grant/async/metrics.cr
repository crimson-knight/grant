module Grant
  module Async
    # Metrics tracking for async operations
    class Metrics
      @@total_operations = 0_i64
      @@active_operations = 0_i64
      @@failed_operations = 0_i64
      @@total_duration = 0_i64 # in microseconds
      @@mutex = Mutex.new

      # Track an operation
      def self.track_operation(&)
        @@mutex.synchronize do
          @@active_operations += 1
          @@total_operations += 1
        end
        start_time = Time.instant

        begin
          yield
        rescue e
          @@mutex.synchronize { @@failed_operations += 1 }
          raise e
        ensure
          duration = Time.instant - start_time
          @@mutex.synchronize do
            @@total_duration += duration.total_microseconds.to_i64
            @@active_operations -= 1
          end
        end
      end

      # Get current metrics
      def self.snapshot : NamedTuple
        @@mutex.synchronize do
          {
            total:           @@total_operations,
            active:          @@active_operations,
            failed:          @@failed_operations,
            success_rate:    calculate_success_rate,
            avg_duration_ms: calculate_avg_duration_ms,
          }
        end
      end

      # Reset all metrics
      def self.reset
        @@mutex.synchronize do
          @@total_operations = 0_i64
          @@active_operations = 0_i64
          @@failed_operations = 0_i64
          @@total_duration = 0_i64
        end
      end

      private def self.calculate_success_rate : Float64
        total = @@total_operations
        return 0.0 if total == 0

        failed = @@failed_operations
        ((total - failed) * 100.0) / total
      end

      private def self.calculate_avg_duration_ms : Float64
        total = @@total_operations
        return 0.0 if total == 0

        duration_us = @@total_duration
        (duration_us / total) / 1000.0
      end
    end
  end
end
