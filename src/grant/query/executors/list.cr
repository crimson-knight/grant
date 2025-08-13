module Grant::Query::Executor
  class List(Model)
    include Shared

    def initialize(@sql : String, @args = [] of Grant::Columns::Type)
    end

    def run : Array(Model)
      log @sql, @args
      
      start_time = Time.monotonic
      results = [] of Model

      begin
        Model.adapter.open do |db|
          db.query @sql, args: @args do |record_set|
            record_set.each do
              results << Model.from_rs record_set
            end
          end
        end
        
        duration = Time.monotonic - start_time
        log_query_with_timing(@sql, @args, duration, results.size, Model.name)
      rescue e
        duration = Time.monotonic - start_time
        Grant::Logs::SQL.error { "Query failed (#{duration.total_milliseconds}ms) - #{@sql} [#{Model.name}] - #{e.message}" }
        raise e
      end

      results
    end

    delegate :[], :first?, :first, :each, :group_by, to: :run
    delegate :to_s, to: :run
  end
end
