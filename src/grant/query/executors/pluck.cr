module Grant::Query::Executor
  class Pluck(Model)
    include Shared

    def initialize(@sql : String, @args = [] of Grant::Columns::Type, @fields : Array(String) = [] of String)
    end

    def run : Array(Array(Grant::Columns::Type))
      log @sql, @args

      start_time = Time.instant
      results = [] of Array(Grant::Columns::Type)

      begin
        adapter = Model.adapter
        copy = ->(cached : Array(Array(Grant::Columns::Type))) { cached.map(&.dup) }
        results = Grant::QueryCache.fetch(adapter, @sql, @args, Model.name, copy) do
          rows = [] of Array(Grant::Columns::Type)
          adapter.open(@sql, @args, Model.name) do |db|
            db.query @sql, args: adapter.normalize_bind_values(@args) do |rs|
              rs.each do
                row = [] of Grant::Columns::Type
                @fields.each do |field|
                  # Read values in order - rs.read advances to next column automatically
                  row << rs.read(Grant::Columns::Type)
                end
                rows << row
              end
            end
          end
          rows
        end

        duration = Time.instant - start_time
        log_query_with_timing(@sql, @args, duration, results.size, Model.name)
      rescue e
        duration = Time.instant - start_time
        Grant::Logs::SQL.error { "Pluck query failed (#{duration.total_milliseconds}ms) - #{@sql} [#{Model.name}] [fields: #{@fields.join(", ")}] - #{e.message}" }
        raise e
      end

      results
    end
  end
end
