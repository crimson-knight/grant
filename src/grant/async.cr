require "./async/promise"
require "./async/result"
require "./async/errors"
require "./async/coordinator"
require "./async/metrics"

module Grant
  # Async convenience features for Grant ORM
  module Async
    # Type aliases for convenience
    alias AsyncResult = Grant::Async::Result
    
    # Module to be included in Grant::Base
    module ClassMethods
      # Async count
      def async_count : AsyncResult(Int64)
        AsyncResult(Int64).new do
          count.to_i64
        end
      end
      
      # Async sum
      def async_sum(column : Symbol | String) : AsyncResult(Float64)
        AsyncResult(Float64).new do
          sum(column)
        end
      end
      
      # Async average
      def async_avg(column : Symbol | String) : AsyncResult(Float64?)
        AsyncResult(Float64?).new do
          avg(column)
        end
      end
      
      # Async min
      def async_min(column : Symbol | String) : AsyncResult(Grant::Columns::Type)
        AsyncResult(Grant::Columns::Type).new do
          min(column)
        end
      end
      
      # Async max
      def async_max(column : Symbol | String) : AsyncResult(Grant::Columns::Type)
        AsyncResult(Grant::Columns::Type).new do
          max(column)
        end
      end
      
      # Async pluck
      def async_pluck(column : Symbol | String) : AsyncResult(Array(Grant::Columns::Type))
        AsyncResult(Array(Grant::Columns::Type)).new do
          pluck(column)
        end
      end
      
      # Async pick (first value)
      def async_pick(column : Symbol | String) : AsyncResult(Grant::Columns::Type?)
        AsyncResult(Grant::Columns::Type?).new do
          pick(column)
        end
      end
      
      # Async find
      def async_find(id) : AsyncResult(self?)
        AsyncResult(self?).new do
          find(id)
        end
      end
      
      # Async find!
      def async_find!(id) : AsyncResult(self)
        AsyncResult(self).new do
          find!(id)
        end
      end
      
      # Async find_by
      def async_find_by(**args) : AsyncResult(self?)
        AsyncResult(self?).new do
          find_by(**args)
        end
      end
      
      # Async find_by!
      def async_find_by!(**args) : AsyncResult(self)
        AsyncResult(self).new do
          find_by!(**args)
        end
      end
      
      # Async first
      def async_first : AsyncResult(self?)
        AsyncResult(self?).new do
          first
        end
      end
      
      # Async first!
      def async_first! : AsyncResult(self)
        AsyncResult(self).new do
          first!
        end
      end
      
      # Async last
      def async_last : AsyncResult(self?)
        AsyncResult(self?).new do
          last
        end
      end
      
      # Async last!
      def async_last! : AsyncResult(self)
        AsyncResult(self).new do
          last!
        end
      end
      
      # Async all
      def async_all : AsyncResult(Array(self))
        AsyncResult(Array(self)).new do
          all.to_a
        end
      end
      
      # Execute multiple async operations in parallel
      def parallel_execute(&block : Coordinator -> Nil) : Coordinator
        coordinator = Coordinator.new
        yield coordinator
        coordinator.wait_all
        coordinator
      end
    end
    
    # Module for query builder async methods
    module QueryMethods(Model)
      # Async select/all
      def async_select : AsyncResult(Array(Model))
        AsyncResult(Array(Model)).new do
          self.select
        end
      end
      
      # Async count
      def async_count : AsyncResult(Int64)
        AsyncResult(Int64).new do
          result = count.run
          case result
          when Int64
            result
          when Array(Int64)
            result.sum  # Sum all group counts
          else
            result.to_i64
          end
        end
      end
      
      # Async sum
      def async_sum(column : Symbol | String) : AsyncResult(Float64)
        AsyncResult(Float64).new do
          sum(column)
        end
      end
      
      # Async avg
      def async_avg(column : Symbol | String) : AsyncResult(Float64?)
        AsyncResult(Float64?).new do
          avg(column)
        end
      end
      
      # Async min
      def async_min(column : Symbol | String) : AsyncResult(Grant::Columns::Type)
        AsyncResult(Grant::Columns::Type).new do
          min(column)
        end
      end
      
      # Async max
      def async_max(column : Symbol | String) : AsyncResult(Grant::Columns::Type)
        AsyncResult(Grant::Columns::Type).new do
          max(column)
        end
      end
      
      # Async exists?
      def async_exists? : AsyncResult(Bool)
        AsyncResult(Bool).new do
          exists?
        end
      end
      
      # Async delete
      def async_delete : AsyncResult(DB::ExecResult)
        AsyncResult(DB::ExecResult).new do
          delete
        end
      end
      
      # Async update_all
      def async_update_all(assignments : String) : AsyncResult(DB::ExecResult)
        AsyncResult(DB::ExecResult).new do
          update_all(assignments)
        end
      end
      
      # Async touch_all
      def async_touch_all(*fields : Symbol) : AsyncResult(Int64)
        time = Time.utc
        AsyncResult(Int64).new do
          touch_all(*fields, time: time)
        end
      end
      
      # Async first
      def async_first : AsyncResult(Model?)
        AsyncResult(Model?).new do
          first
        end
      end
      
      # Async first!
      def async_first! : AsyncResult(Model)
        AsyncResult(Model).new do
          first!
        end
      end
      
      # Async last
      def async_last : AsyncResult(Model?)
        AsyncResult(Model?).new do
          last
        end
      end
      
      # Async pluck
      def async_pluck(column : Symbol | String) : AsyncResult(Array(Grant::Columns::Type))
        AsyncResult(Array(Grant::Columns::Type)).new do
          pluck(column)
        end
      end
      
      # Async pick
      def async_pick(column : Symbol | String) : AsyncResult(Grant::Columns::Type?)
        AsyncResult(Grant::Columns::Type?).new do
          pick(column)
        end
      end
    end
  end
end