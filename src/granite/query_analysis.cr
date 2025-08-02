# Query analysis helpers for Granite ORM
#
# Provides tools to detect and analyze potential performance issues like N+1 queries
#
module Granite::QueryAnalysis
  # N+1 query detector
  class N1Detector
    # Track queries by model and operation
    @query_log = {} of String => Array(QueryRecord)
    @enabled = false
    
    record QueryRecord, 
      sql : String,
      model : String,
      timestamp : Time,
      duration_ms : Float64,
      association : String? = nil
    
    def self.instance
      @@instance ||= new
    end
    
    def enable!
      @enabled = true
      @query_log.clear
      self
    end
    
    def disable!
      @enabled = false
      self
    end
    
    def enabled?
      @enabled
    end
    
    # Record a query for analysis
    def record_query(sql : String, model : String, duration_ms : Float64, association : String? = nil)
      return unless @enabled
      
      key = "#{model}##{extract_operation(sql)}"
      @query_log[key] ||= [] of QueryRecord
      @query_log[key] << QueryRecord.new(
        sql: sql,
        model: model,
        timestamp: Time.local,
        duration_ms: duration_ms,
        association: association
      )
    end
    
    # Analyze recorded queries for N+1 patterns
    def analyze : Analysis
      potential_n1s = [] of N1Issue
      
      @query_log.each do |key, queries|
        # Skip if only one query
        next if queries.size <= 1
        
        # Check for similar queries (potential N+1)
        if similar_queries?(queries)
          potential_n1s << N1Issue.new(
            model: queries.first.model,
            operation: extract_operation(queries.first.sql),
            query_count: queries.size,
            total_duration_ms: queries.sum(&.duration_ms),
            sample_sql: queries.first.sql,
            association: queries.first.association
          )
        end
      end
      
      Analysis.new(
        total_queries: @query_log.values.flatten.size,
        unique_queries: @query_log.size,
        potential_n1_issues: potential_n1s,
        total_duration_ms: @query_log.values.flatten.sum(&.duration_ms)
      )
    end
    
    # Clear recorded queries
    def clear
      @query_log.clear
    end
    
    # Run a block with N+1 detection enabled
    def self.detect(&) : Analysis
      detector = instance
      detector.enable!
      analysis = nil
      
      begin
        yield
      ensure
        analysis = detector.analyze
        detector.disable!
        detector.clear
        
        if analysis.has_issues?
          Granite::Logs::Query.warn { "Potential N+1 queries detected - #{analysis.potential_n1_issues.size} issues, #{analysis.total_queries} total queries (#{analysis.total_duration_ms}ms)" }
          
          analysis.potential_n1_issues.each do |issue|
            Granite::Logs::Query.warn { "N+1 Query Pattern - #{issue.model}##{issue.operation}: #{issue.query_count} queries (#{issue.total_duration_ms}ms) [#{issue.association || "no association"}]" }
          end
        end
      end
      
      analysis.not_nil!
    end
    
    private def extract_operation(sql : String) : String
      case sql
      when /SELECT/i
        "select"
      when /INSERT/i
        "insert"
      when /UPDATE/i
        "update"
      when /DELETE/i
        "delete"
      else
        "unknown"
      end
    end
    
    private def similar_queries?(queries : Array(QueryRecord)) : Bool
      return false if queries.size < 2
      
      # Get the SQL pattern (remove specific values)
      base_pattern = normalize_sql(queries.first.sql)
      
      # Check if all queries match the pattern
      queries.all? { |q| normalize_sql(q.sql) == base_pattern }
    end
    
    private def normalize_sql(sql : String) : String
      # Replace specific values with placeholders to find patterns
      sql
        .gsub(/\b\d+\b/, "?")           # Replace numbers
        .gsub(/'[^']*'/, "?")            # Replace strings
        .gsub(/\$\d+/, "?")              # Replace numbered params
        .gsub(/\s+/, " ")                # Normalize whitespace
        .strip
    end
    
    record N1Issue,
      model : String,
      operation : String,
      query_count : Int32,
      total_duration_ms : Float64,
      sample_sql : String,
      association : String?
    
    record Analysis,
      total_queries : Int32,
      unique_queries : Int32,
      potential_n1_issues : Array(N1Issue),
      total_duration_ms : Float64 do
      
      def has_issues?
        !potential_n1_issues.empty?
      end
      
      def to_s(io)
        io << "Query Analysis:\n"
        io << "  Total queries: #{total_queries}\n"
        io << "  Unique patterns: #{unique_queries}\n"
        io << "  Total duration: #{total_duration_ms.round(2)}ms\n"
        
        if has_issues?
          io << "  ⚠️  Potential N+1 issues found:\n"
          potential_n1_issues.each do |issue|
            io << "    - #{issue.model}: #{issue.query_count} similar queries"
            io << " (#{issue.total_duration_ms.round(2)}ms total)"
            if issue.association
              io << " [association: #{issue.association}]"
            end
            io << "\n"
          end
        else
          io << "  ✓ No N+1 issues detected\n"
        end
      end
    end
  end
  
  # Query statistics collector
  class QueryStats
    @stats = {} of String => StatEntry
    @enabled = false
    
    record StatEntry,
      count : Int32,
      total_duration_ms : Float64,
      min_duration_ms : Float64,
      max_duration_ms : Float64,
      avg_duration_ms : Float64
    
    def self.instance
      @@instance ||= new
    end
    
    def enable!
      @enabled = true
      @stats.clear
      self
    end
    
    def disable!
      @enabled = false
      self
    end
    
    def record(model : String, operation : String, duration_ms : Float64)
      return unless @enabled
      
      key = "#{model}##{operation}"
      
      if existing = @stats[key]?
        count = existing.count + 1
        total = existing.total_duration_ms + duration_ms
        min = Math.min(existing.min_duration_ms, duration_ms)
        max = Math.max(existing.max_duration_ms, duration_ms)
        avg = total / count
        
        @stats[key] = StatEntry.new(
          count: count,
          total_duration_ms: total,
          min_duration_ms: min,
          max_duration_ms: max,
          avg_duration_ms: avg
        )
      else
        @stats[key] = StatEntry.new(
          count: 1,
          total_duration_ms: duration_ms,
          min_duration_ms: duration_ms,
          max_duration_ms: duration_ms,
          avg_duration_ms: duration_ms
        )
      end
    end
    
    def report
      return if @stats.empty?
      
      Granite::Logs::Query.info { "Query Statistics Summary - #{@stats.size} operations, #{@stats.values.sum(&.count)} queries (#{@stats.values.sum(&.total_duration_ms)}ms)" }
      
      # Sort by total duration (descending)
      sorted_stats = @stats.to_a.sort_by { |_, stat| -stat.total_duration_ms }
      
      sorted_stats.each do |key, stat|
        model, operation = key.split("#", 2)
        
        Granite::Logs::Query.info { "Query Stats - #{model}##{operation}: #{stat.count} queries, total: #{stat.total_duration_ms.round(2)}ms, avg: #{stat.avg_duration_ms.round(2)}ms, min: #{stat.min_duration_ms.round(2)}ms, max: #{stat.max_duration_ms.round(2)}ms" }
      end
    end
    
    def clear
      @stats.clear
    end
  end
  
  # Integration with Granite's query execution
  module Integration
    macro included
      # Hook into query execution to record metrics
      def log_query_with_timing(sql : String, args : Array(Granite::Columns::Type), duration : Time::Span, row_count : Int32? = nil, model_name : String? = nil)
        previous_def
        
        # Record for N+1 detection
        if detector = Granite::QueryAnalysis::N1Detector.instance
          if detector.enabled? && model_name
            detector.record_query(sql, model_name, duration.total_milliseconds)
          end
        end
        
        # Record for statistics
        if stats = Granite::QueryAnalysis::QueryStats.instance
          if stats.@enabled && model_name
            operation = case sql
            when /SELECT/i then "select"
            when /INSERT/i then "insert"
            when /UPDATE/i then "update"
            when /DELETE/i then "delete"
            else "other"
            end
            
            stats.record(model_name, operation, duration.total_milliseconds)
          end
        end
      end
    end
  end
end

# Extend executors with analysis integration
module Granite::Query::Executor
  module Shared
    include Granite::QueryAnalysis::Integration
  end
end