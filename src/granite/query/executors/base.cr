module Granite::Query::Executor
  module Shared
    def raw_sql : String
      @sql
    end

    def log(*messages)
      messages.each { |message| Log.debug { message } }
    end
    
    # Enhanced logging with timing and structured data
    def log_query(sql : String, args : Array(Granite::Columns::Type), model_name : String? = nil)
      Granite::Logs::SQL.debug &.emit("Query prepared",
        sql: sql,
        model: model_name,
        args_count: args.size
      )
    end
    
    def log_query_with_timing(sql : String, args : Array(Granite::Columns::Type), duration : Time::Span, row_count : Int32? = nil, model_name : String? = nil)
      duration_ms = duration.total_milliseconds
      
      # Log as warning if query is slow (> 100ms)
      if duration_ms > 100
        Granite::Logs::SQL.warn &.emit("Slow query detected",
          sql: sql,
          model: model_name,
          duration_ms: duration_ms,
          row_count: row_count,
          args_count: args.size
        )
      else
        Granite::Logs::SQL.debug &.emit("Query executed",
          sql: sql,
          model: model_name,
          duration_ms: duration_ms,
          row_count: row_count,
          args_count: args.size
        )
      end
    end
  end
end
