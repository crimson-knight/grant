module Granite::Query::Executor
  module Shared
    def raw_sql : String
      @sql
    end

    def log(*messages)
      messages.each { |message| Granite::Logs::SQL.debug { message } }
    end
    
    # Enhanced logging with timing and structured data
    def log_query(sql : String, args : Array(Granite::Columns::Type), model_name : String? = nil)
      Granite::Logs::SQL.debug { "Query prepared - #{sql} [#{model_name}] [args: #{args.size}]" }
    end
    
    def log_query_with_timing(sql : String, args : Array(Granite::Columns::Type), duration : Time::Span, row_count : Int32? = nil, model_name : String? = nil)
      duration_ms = duration.total_milliseconds
      
      # Log as warning if query is slow (> 100ms)
      if duration_ms > 100
        Granite::Logs::SQL.warn { "Slow query detected (#{duration_ms}ms) - #{sql} [#{model_name}] [rows: #{row_count}]" }
      else
        Granite::Logs::SQL.debug { "Query executed (#{duration_ms}ms) - #{sql} [#{model_name}] [rows: #{row_count}]" }
      end
    end
  end
end
