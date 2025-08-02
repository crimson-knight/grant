module Granite::Query::Executor
  class Pluck(Model)
    include Shared

    def initialize(@sql : String, @args = [] of Granite::Columns::Type, @fields : Array(String) = [] of String)
    end

    def run : Array(Array(Granite::Columns::Type))
      log @sql, @args
      
      start_time = Time.monotonic
      results = [] of Array(Granite::Columns::Type)

      begin
        Model.adapter.open do |db|
          db.query @sql, args: @args do |rs|
            rs.each do
              row = [] of Granite::Columns::Type
              @fields.each do |field|
                # Read values in order - rs.read advances to next column automatically
                row << rs.read(Granite::Columns::Type)
              end
              results << row
            end
          end
        end
        
        duration = Time.monotonic - start_time
        log_query_with_timing(@sql, @args, duration, results.size, Model.name)
      rescue e
        duration = Time.monotonic - start_time
        Granite::Logs::SQL.error { "Pluck query failed (#{duration.total_milliseconds}ms) - #{@sql} [#{Model.name}] [fields: #{@fields.join(", ")}] - #{e.message}" }
        raise e
      end

      results
    end
  end
end