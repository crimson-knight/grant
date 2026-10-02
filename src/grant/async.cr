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
      def async_sum(column : Symbol | String) : AsyncResult(Grant::Query::Builder::SumValue)
        query = current_scope
        AsyncResult(Grant::Query::Builder::SumValue).new do
          result = query.sum(column)
          raise ArgumentError.new("async_sum on a grouped scope returns a Hash per group") if result.is_a?(Hash)
          result
        end
      end

      # Async average
      def async_avg(column : Symbol | String) : AsyncResult(Float64?)
        query = current_scope
        AsyncResult(Float64?).new do
          result = query.avg(column)
          raise ArgumentError.new("async_avg on a grouped scope returns a Hash per group") if result.is_a?(Hash)
          result
        end
      end

      # Async min
      def async_min(column : Symbol | String) : AsyncResult(Grant::Columns::Type)
        query = current_scope
        AsyncResult(Grant::Columns::Type).new do
          result = query.min(column)
          raise ArgumentError.new("async_min on a grouped scope returns a Hash per group") if result.is_a?(Hash)
          result
        end
      end

      # Async max
      def async_max(column : Symbol | String) : AsyncResult(Grant::Columns::Type)
        query = current_scope
        AsyncResult(Grant::Columns::Type).new do
          result = query.max(column)
          raise ArgumentError.new("async_max on a grouped scope returns a Hash per group") if result.is_a?(Hash)
          result
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
          query.own_order_fields << {field: primary_name, direction: Grant::Query::Builder::Sort::Ascending}
        end
        AsyncResult(Grant::Columns::Type?).new do
          query.pick(column).try(&.first)
        end
      end

      # Async average, ActiveRecord's name for `async_avg`
      def async_average(column : Symbol | String) : AsyncResult(Float64?)
        async_avg(column)
      end

      # Async primary keys of the current scope
      def async_ids : AsyncResult(Array(Grant::Columns::Type))
        query = current_scope
        AsyncResult(Array(Grant::Columns::Type)).new do
          query.ids
        end
      end

      # Async existence check of the current scope
      def async_exists? : AsyncResult(Bool)
        query = current_scope
        AsyncResult(Bool).new do
          query.exists?
        end
      end

      # Async `find_by_sql`: hydrates the rows of *sql* as this model on a
      # background fiber. Raw SQL gets no default scope, so a scoped model
      # raises unless the call sits inside `unscoped { }`, as `find_by_sql`.
      def async_find_by_sql(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : AsyncResult(Array(self))
        ensure_raw_sql_unscoped!
        AsyncResult(Array(self)).new do
          unscoped { |_| find_by_sql(sql, binds) }
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
          query.first || raise Grant::Querying::NotFound.new("No #{name} found where #{primary_name} = #{id}")
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
          query.first || raise Grant::Querying::NotFound.new("No #{name} found where #{args}")
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
          query.first || raise Grant::Querying::NotFound.new("No #{name} found with first")
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
          query.last || raise Grant::Querying::NotFound.new("No #{name} found with last")
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
      def parallel_execute(& : Coordinator -> Nil) : Coordinator
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
      def async_sum(column : Symbol | String) : AsyncResult(Grant::Query::Builder::SumValue)
        AsyncResult(Grant::Query::Builder::SumValue).new do
          result = sum(column)
          raise ArgumentError.new("async_sum on a grouped relation returns a Hash per group") if result.is_a?(Hash)
          result
        end
      end

      # Async avg
      def async_avg(column : Symbol | String) : AsyncResult(Float64?)
        AsyncResult(Float64?).new do
          result = avg(column)
          raise ArgumentError.new("async_avg on a grouped relation returns a Hash per group") if result.is_a?(Hash)
          result
        end
      end

      # Async min
      def async_min(column : Symbol | String) : AsyncResult(Grant::Columns::Type)
        AsyncResult(Grant::Columns::Type).new do
          result = min(column)
          raise ArgumentError.new("async_min on a grouped relation returns a Hash per group") if result.is_a?(Hash)
          result
        end
      end

      # Async max
      def async_max(column : Symbol | String) : AsyncResult(Grant::Columns::Type)
        AsyncResult(Grant::Columns::Type).new do
          result = max(column)
          raise ArgumentError.new("async_max on a grouped relation returns a Hash per group") if result.is_a?(Hash)
          result
        end
      end

      # Async exists?
      def async_exists? : AsyncResult(Bool)
        AsyncResult(Bool).new do
          exists?
        end
      end

      # Async primary keys of the relation
      def async_ids : AsyncResult(Array(Grant::Columns::Type))
        AsyncResult(Array(Grant::Columns::Type)).new do
          ids
        end
      end

      # Async average, ActiveRecord's name for `async_avg`
      def async_average(column : Symbol | String) : AsyncResult(Float64?)
        async_avg(column)
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
          pick(column).try(&.first?)
        end
      end
    end
  end
end
