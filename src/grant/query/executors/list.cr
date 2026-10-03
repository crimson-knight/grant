module Grant::Query::Executor
  # The database cursor loop is identical for every model. Keep it in one
  # non-generic runner and pass only the model-specific row hydration step.
  class SharedListRunner
    alias RowLoader = Proc(DB::ResultSet, Grant::Adapter::Base, Nil)

    def self.run(adapter : Grant::Adapter::Base, sql : String, args : Array(Grant::Columns::Type), model_name : String, row_loader : RowLoader) : Nil
      adapter.open(sql, args, model_name) do |db|
        db.query sql, args: adapter.normalize_bind_values(args) do |record_set|
          row_loader.call(record_set, adapter)
        end
      end
    end
  end

  class List(Model)
    include Shared

    def initialize(@sql : String, @args = [] of Grant::Columns::Type)
    end

    def run : Array(Model)
      log @sql, @args

      start_time = Time.instant
      results = [] of Model

      begin
        adapter = Model.adapter
        copy = ->(rows : Array(Model)) { rows.map(&.clone.as(Model)) }
        results = Grant::QueryCache.fetch(adapter, @sql, @args, Model.name, copy) do
          rows = [] of Model
          row_loader : SharedListRunner::RowLoader = ->(record_set : DB::ResultSet, current_adapter : Grant::Adapter::Base) do
            plan = Model.__column_plan(record_set, current_adapter)
            record_set.each do
              rows << Model.from_rs(record_set, plan)
            end
            nil
          end
          SharedListRunner.run(adapter, @sql, @args, Model.name, row_loader)
          rows
        end

        duration = Time.instant - start_time
        log_query_with_timing(@sql, @args, duration, results.size, Model.name)
      rescue e
        duration = Time.instant - start_time
        Grant::Logs::SQL.error { "Query failed (#{duration.total_milliseconds}ms) - #{@sql} [#{Model.name}] - #{e.message}" }
        raise e
      end

      results
    end

    delegate :[], :first?, :first, :each, :group_by, to: :run
    delegate :to_s, to: :run
  end
end
