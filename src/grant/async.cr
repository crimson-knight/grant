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
        query = current_scope
        AsyncResult(Int64).new do
          query.size
        end
      end

      # Async sum
      def async_sum(column : Symbol | String) : AsyncResult(Float64)
        query = current_scope
        AsyncResult(Float64).new do
          query.sum(column)
        end
      end

      # Async average
      def async_avg(column : Symbol | String) : AsyncResult(Float64?)
        query = current_scope
        AsyncResult(Float64?).new do
          query.avg(column)
        end
      end

      # Async min
      def async_min(column : Symbol | String) : AsyncResult(Grant::Columns::Type)
        query = current_scope
        AsyncResult(Grant::Columns::Type).new do
          query.min(column)
        end
      end

      # Async max
      def async_max(column : Symbol | String) : AsyncResult(Grant::Columns::Type)
        query = current_scope
        AsyncResult(Grant::Columns::Type).new do
          query.max(column)
        end
      end

      # Async pluck
      def async_pluck(column : Symbol | String) : AsyncResult(Array(Grant::Columns::Type))
        query = current_scope
        AsyncResult(Array(Grant::Columns::Type)).new do
          query.pluck(column).map(&.first)
        end
      end

      # Async pick (first value)
      def async_pick(column : Symbol | String) : AsyncResult(Grant::Columns::Type?)
        query = current_scope
        if query.order_fields.empty?
          query.order_fields << {field: primary_name, direction: Grant::Query::Builder::Sort::Ascending}
        end
        AsyncResult(Grant::Columns::Type?).new do
          query.pick(column).try(&.first)
        end
      end

      # Async find
      def async_find(id) : AsyncResult(self?)
        query = current_scope.where(primary_name, :eq, id.as(Grant::Columns::Type))
        AsyncResult(self?).new do
          query.first
        end
      end

      # Async find!
      def async_find!(id) : AsyncResult(self)
        query = current_scope.where(primary_name, :eq, id.as(Grant::Columns::Type))
        AsyncResult(self).new do
          query.first || raise Grant::Querying::NotFound.new("No #{self.name} found where #{primary_name} = #{id}")
        end
      end

      # Async find_by
      def async_find_by(**args) : AsyncResult(self?)
        query = current_scope.where(**args)
        AsyncResult(self?).new do
          query.first
        end
      end

      # Async find_by!
      def async_find_by!(**args) : AsyncResult(self)
        query = current_scope.where(**args)
        AsyncResult(self).new do
          query.first || raise Grant::Querying::NotFound.new("No #{self.name} found where #{args}")
        end
      end

      # Async first
      def async_first : AsyncResult(self?)
        query = current_scope
        AsyncResult(self?).new do
          query.first
        end
      end

      # Async first!
      def async_first! : AsyncResult(self)
        query = current_scope
        AsyncResult(self).new do
          query.first || raise Grant::Querying::NotFound.new("No #{self.name} found with first")
        end
      end

      # Async last
      def async_last : AsyncResult(self?)
        query = current_scope
        AsyncResult(self?).new do
          query.last
        end
      end

      # Async last!
      def async_last! : AsyncResult(self)
        query = current_scope
        AsyncResult(self).new do
          query.last || raise Grant::Querying::NotFound.new("No #{self.name} found with last")
        end
      end

      # Async all
      def async_all : AsyncResult(Array(self))
        query = current_scope
        AsyncResult(Array(self)).new do
          query.select
        end
      end

      # Rails-familiar alias for `async_all` at the model-class level.
      #
      # ```
      # result = User.load_async # whole-table read on a fiber
      # users = result.wait
      # ```
      #
      # For filtered reads, prefer the query-builder form
      # (`User.where(...).load_async`).
      def load_async : AsyncResult(Array(self))
        async_all
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

      # Rails-familiar alias for `async_select`.
      #
      # Kicks off the query on a background fiber and returns an
      # `Async::Result(Array(Model))` immediately. Call `.wait` to block for
      # the rows, or chain `.then`/`.map`/`.on_error`:
      #
      # ```
      # result = User.where(active: true).load_async
      # # ... do other work / fire more queries ...
      # users = result.wait
      # ```
      #
      # Mirrors ActiveRecord's `Relation#load_async`. Unlike Rails (which
      # depends on a thread pool and inherits the GVL), this runs on a cheap
      # cooperative fiber.
      def load_async : AsyncResult(Array(Model))
        async_select
      end

      # Async count
      def async_count : AsyncResult(Int64)
        AsyncResult(Int64).new do
          size
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
