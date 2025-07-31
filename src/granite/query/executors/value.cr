module Granite::Query::Executor
  class Value(Model, Scalar)
    include Shared

    def initialize(@sql : String, @args = [] of Granite::Columns::Type, @default : Scalar = nil)
    end

    def run : Scalar
      log @sql, @args
      # db.scalar raises when a query returns 0 results, so I'm using query_one?
      # https://github.com/crystal-lang/crystal-db/blob/7d30e9f50e478cb6404d16d2ce91e639b6f9c476/src/db/statement.cr#L18

      if @default.nil?
        raise "No default provided"
      else
        start_time = Time.monotonic
        begin
          result = Model.adapter.open do |db|
            db.query_one?(@sql, args: @args, as: Scalar) || @default
          end
          
          duration = Time.monotonic - start_time
          log_query_with_timing(@sql, @args, duration, 1, Model.name)
          result
        rescue e
          duration = Time.monotonic - start_time
          Granite::Logs::SQL.error &.emit("Query failed",
            sql: @sql,
            model: Model.name,
            duration_ms: duration.total_milliseconds,
            error: e.message
          )
          raise e
        end
      end
    end

    delegate :<, :>, :<=, :>=, to: :run
    delegate :to_i, :to_s, to: :run
  end
end
