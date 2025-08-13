module Grant::Query::Executor
  module Shared
    def raw_sql : String
      @sql
    end

    def log(*messages)
      messages.each { |message| Grant::Logs::SQL.debug { message } }
    end
    
    # Enhanced logging with timing and structured data
    def log_query(sql : String, args : Array(Grant::Columns::Type), model_name : String? = nil)
      Grant::Logs::SQL.debug { "Query prepared - #{sql} [#{model_name}] [args: #{args.size}]" }
    end
    
    def log_query_with_timing(sql : String, args : Array(Grant::Columns::Type), duration : Time::Span, row_count : Int32? = nil, model_name : String? = nil)
      duration_ms = duration.total_milliseconds
      
      # Log as warning if query is slow (> 100ms)
      if duration_ms > 100
        Grant::Logs::SQL.warn { "Slow query detected (#{duration_ms}ms) - #{sql} [#{model_name}] [rows: #{row_count}]" }
      else
        Grant::Logs::SQL.debug { "Query executed (#{duration_ms}ms) - #{sql} [#{model_name}] [rows: #{row_count}]" }
      end
    end
  end
end
