---
title: "Monitoring and Performance Analysis"
category: "infrastructure"
subcategory: "observability"
tags: ["monitoring", "logging", "metrics", "performance", "query-analysis", "observability", "telemetry"]
complexity: "advanced"
version: "1.0.0"
prerequisites: ["../core-features/querying-and-scopes.md", "database-scaling.md"]
related_docs: ["async-concurrency.md", "transactions-and-locking.md", "../advanced/performance/query-optimization.md"]
last_updated: "2025-01-13"
estimated_read_time: "20 minutes"
use_cases: ["production-monitoring", "performance-tuning", "debugging", "alerting", "capacity-planning"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Monitoring and Performance Analysis

Comprehensive guide to monitoring, logging, performance analysis, and observability for Grant applications, including query analysis, metrics collection, and production debugging.

## Overview

Proper monitoring and performance analysis are crucial for production applications. This guide covers:
- Structured logging and log aggregation
- Query performance monitoring
- Metrics collection and instrumentation
- Real-time performance analysis
- Alerting and anomaly detection
- Distributed tracing
- Production debugging techniques

## Logging Infrastructure

### Structured Logging

```crystal
require "log"

module Grant::Logging
  class StructuredBackend < Log::IOBackend
    def write(entry : Log::Entry)
      io << {
        timestamp: entry.timestamp,
        severity: entry.severity.to_s,
        source: entry.source,
        message: entry.message,
        context: entry.context.to_h,
        data: entry.data.to_h,
        exception: format_exception(entry.exception)
      }.to_json
      io << "\n"
    end
    
    private def format_exception(ex : Exception?) : Hash(String, String)?
      return nil unless ex
      
      {
        "class" => ex.class.name,
        "message" => ex.message || "",
        "backtrace" => ex.backtrace.join("\n")
      }
    end
  end
  
  # Configure logging
  def self.setup
    backend = StructuredBackend.new
    
    Log.setup do |c|
      c.bind "grant.*", :debug, backend
      c.bind "db.*", :info, backend
      c.bind "app.*", :info, backend
    end
  end
end

# Query logging
module QueryLogging
  macro included
    class_property query_logger : Log = Log.for("grant.query")
    
    def self.log_query(sql : String, params : Array(DB::Any), duration : Time::Span)
      query_logger.info do
        {
          sql: sql,
          params: sanitize_params(params),
          duration_ms: duration.total_milliseconds,
          model: self.name,
          caller: extract_caller
        }
      end
      
      # Slow query warning
      if duration > 100.milliseconds
        query_logger.warn { "Slow query detected: #{duration.total_milliseconds}ms" }
      end
    end
    
    private def self.sanitize_params(params : Array(DB::Any)) : Array(String)
      params.map do |param|
        case param
        when String
          param.size > 100 ? "#{param[0...100]}..." : param
        else
          param.to_s
        end
      end
    end
    
    private def self.extract_caller : String
      caller_locations(3, 1).first.to_s
    end
  end
end
```

### Contextual Logging

```crystal
class RequestContext
  class_property current : RequestContext?
  
  property request_id : String
  property user_id : Int64?
  property session_id : String?
  property ip_address : String?
  property start_time : Time
  
  def initialize(@request_id = UUID.random.to_s)
    @start_time = Time.utc
  end
  
  def self.with_context(context : RequestContext, &block)
    old_context = @@current
    @@current = context
    
    Log.context.set(
      request_id: context.request_id,
      user_id: context.user_id,
      session_id: context.session_id
    )
    
    yield
  ensure
    @@current = old_context
    Log.context.clear
  end
  
  def elapsed_time : Time::Span
    Time.utc - start_time
  end
end

# Usage in application
context = RequestContext.new
context.user_id = current_user.id

RequestContext.with_context(context) do
  # All logs within this block include context
  User.find(id)  # Logs include request_id, user_id
end
```

### Log Aggregation

```crystal
class LogAggregator
  def initialize(@buffer_size : Int32 = 1000, @flush_interval : Time::Span = 5.seconds)
    @buffer = [] of String
    @mutex = Mutex.new
    
    spawn flush_periodically
  end
  
  def add(entry : String)
    @mutex.synchronize do
      @buffer << entry
      flush if @buffer.size >= @buffer_size
    end
  end
  
  def flush
    return if @buffer.empty?
    
    logs_to_send = @mutex.synchronize do
      current = @buffer
      @buffer = [] of String
      current
    end
    
    send_to_service(logs_to_send)
  end
  
  private def flush_periodically
    loop do
      sleep @flush_interval
      flush
    end
  end
  
  private def send_to_service(logs : Array(String))
    # Send to log aggregation service (e.g., Elasticsearch, Datadog)
    HTTP::Client.post(
      ENV["LOG_AGGREGATOR_URL"],
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: {logs: logs}.to_json
    )
  rescue ex
    Log.error(exception: ex) { "Failed to send logs to aggregator" }
  end
end
```

## Query Performance Monitoring

### Query Analyzer

```crystal
class QueryAnalyzer
  struct QueryStats
    property sql : String
    property count : Int32 = 0
    property total_time : Time::Span = Time::Span.zero
    property min_time : Time::Span = Time::Span::MAX
    property max_time : Time::Span = Time::Span.zero
    property avg_time : Time::Span = Time::Span.zero
    property last_executed : Time = Time.utc
    
    def update(duration : Time::Span)
      @count += 1
      @total_time += duration
      @min_time = duration if duration < @min_time
      @max_time = duration if duration > @max_time
      @avg_time = @total_time / @count
      @last_executed = Time.utc
    end
  end
  
  @@stats = {} of String => QueryStats
  @@mutex = Mutex.new
  
  def self.record(sql : String, duration : Time::Span)
    normalized_sql = normalize_sql(sql)
    
    @@mutex.synchronize do
      stats = @@stats[normalized_sql] ||= QueryStats.new(sql: normalized_sql)
      stats.update(duration)
    end
  end
  
  def self.report : Array(QueryStats)
    @@mutex.synchronize do
      @@stats.values.sort_by(&.total_time).reverse
    end
  end
  
  def self.slow_queries(threshold : Time::Span = 100.milliseconds) : Array(QueryStats)
    report.select { |stats| stats.avg_time > threshold }
  end
  
  def self.most_frequent(limit : Int32 = 10) : Array(QueryStats)
    report.sort_by(&.count).reverse.first(limit)
  end
  
  private def self.normalize_sql(sql : String) : String
    # Remove specific values to group similar queries
    sql.gsub(/\b\d+\b/, "?")         # Replace numbers
       .gsub(/'[^']*'/, "?")          # Replace strings
       .gsub(/\s+/, " ")              # Normalize whitespace
       .strip
  end
end

# Hook into Grant
abstract class Grant::Base
  def self.query(sql : String, params = [] of DB::Any)
    start = Time.monotonic
    result = connection.query(sql, params)
    duration = Time.monotonic - start
    
    QueryAnalyzer.record(sql, duration)
    QueryLogging.log_query(sql, params, duration)
    
    result
  end
end
```

### Explain Plan Analysis

```crystal
class ExplainAnalyzer
  struct ExplainResult
    property query_plan : String
    property estimated_cost : Float64?
    property actual_time : Float64?
    property rows : Int32?
    property warnings : Array(String) = [] of String
  end
  
  def self.analyze(sql : String, params = [] of DB::Any) : ExplainResult
    explain_sql = "EXPLAIN ANALYZE #{sql}"
    
    result = ExplainResult.new(query_plan: "")
    
    Grant.connection.query(explain_sql, params) do |rs|
      plan_lines = [] of String
      
      while rs.move_next
        line = rs.read(String)
        plan_lines << line
        
        # Parse key metrics
        if line.includes?("cost=")
          result.estimated_cost = extract_cost(line)
        end
        
        if line.includes?("actual time=")
          result.actual_time = extract_actual_time(line)
        end
        
        if line.includes?("rows=")
          result.rows = extract_rows(line)
        end
        
        # Detect performance issues
        check_for_warnings(line, result.warnings)
      end
      
      result.query_plan = plan_lines.join("\n")
    end
    
    result
  end
  
  private def self.check_for_warnings(line : String, warnings : Array(String))
    warnings << "Sequential scan detected" if line.includes?("Seq Scan")
    warnings << "Missing index" if line.includes?("Filter:")
    warnings << "Nested loop on large table" if line.includes?("Nested Loop") && line.includes?("rows=")
    warnings << "Sort operation in memory" if line.includes?("Sort Method: quicksort")
  end
  
  private def self.extract_cost(line : String) : Float64?
    if match = line.match(/cost=(\d+\.\d+)\.\.(\d+\.\d+)/)
      match[2].to_f
    end
  end
  
  private def self.extract_actual_time(line : String) : Float64?
    if match = line.match(/actual time=(\d+\.\d+)\.\.(\d+\.\d+)/)
      match[2].to_f
    end
  end
  
  private def self.extract_rows(line : String) : Int32?
    if match = line.match(/rows=(\d+)/)
      match[1].to_i
    end
  end
end

# Automatic slow query explanation
class SlowQueryExplainer
  def self.explain_if_slow(sql : String, duration : Time::Span, threshold : Time::Span = 100.milliseconds)
    return unless duration > threshold
    
    spawn do
      result = ExplainAnalyzer.analyze(sql)
      
      Log.warn do
        {
          message: "Slow query detected",
          sql: sql,
          duration_ms: duration.total_milliseconds,
          query_plan: result.query_plan,
          warnings: result.warnings
        }
      end
    end
  end
end
```

## Metrics Collection

### Metrics Registry

```crystal
class MetricsRegistry
  abstract class Metric
    getter name : String
    getter tags : Hash(String, String)
    
    def initialize(@name, @tags = {} of String => String)
    end
    
    abstract def value : Float64
    abstract def reset
  end
  
  class Counter < Metric
    @value : Atomic(Int64) = Atomic(Int64).new(0)
    
    def increment(amount : Int64 = 1)
      @value.add(amount)
    end
    
    def value : Float64
      @value.get.to_f
    end
    
    def reset
      @value.set(0)
    end
  end
  
  class Gauge < Metric
    @value : Atomic(Float64) = Atomic(Float64).new(0.0)
    
    def set(value : Float64)
      @value.set(value)
    end
    
    def value : Float64
      @value.get
    end
    
    def reset
      @value.set(0.0)
    end
  end
  
  class Histogram < Metric
    @values : Array(Float64) = [] of Float64
    @mutex : Mutex = Mutex.new
    
    def observe(value : Float64)
      @mutex.synchronize do
        @values << value
      end
    end
    
    def value : Float64
      percentile(0.5)  # Return median
    end
    
    def percentile(p : Float64) : Float64
      @mutex.synchronize do
        return 0.0 if @values.empty?
        
        sorted = @values.sort
        index = (sorted.size * p).to_i
        sorted[index]
      end
    end
    
    def reset
      @mutex.synchronize do
        @values.clear
      end
    end
  end
  
  @@metrics = {} of String => Metric
  
  def self.counter(name : String, tags = {} of String => String) : Counter
    key = metric_key(name, tags)
    @@metrics[key] ||= Counter.new(name, tags)
    @@metrics[key].as(Counter)
  end
  
  def self.gauge(name : String, tags = {} of String => String) : Gauge
    key = metric_key(name, tags)
    @@metrics[key] ||= Gauge.new(name, tags)
    @@metrics[key].as(Gauge)
  end
  
  def self.histogram(name : String, tags = {} of String => String) : Histogram
    key = metric_key(name, tags)
    @@metrics[key] ||= Histogram.new(name, tags)
    @@metrics[key].as(Histogram)
  end
  
  def self.collect : Array(NamedTuple(name: String, value: Float64, tags: Hash(String, String)))
    @@metrics.map do |_, metric|
      {name: metric.name, value: metric.value, tags: metric.tags}
    end
  end
  
  private def self.metric_key(name : String, tags : Hash(String, String)) : String
    tag_str = tags.map { |k, v| "#{k}=#{v}" }.join(",")
    "#{name}:#{tag_str}"
  end
end
```

### Application Metrics

```crystal
module ApplicationMetrics
  # Database metrics
  def self.record_query(model : String, operation : String, duration : Time::Span)
    MetricsRegistry.counter(
      "db.queries.total",
      {"model" => model, "operation" => operation}
    ).increment
    
    MetricsRegistry.histogram(
      "db.queries.duration",
      {"model" => model, "operation" => operation}
    ).observe(duration.total_milliseconds)
  end
  
  def self.record_connection_pool_stats(pool : ConnectionPool)
    stats = pool.stats
    
    MetricsRegistry.gauge(
      "db.connections.active"
    ).set(stats[:active].to_f)
    
    MetricsRegistry.gauge(
      "db.connections.idle"
    ).set(stats[:idle].to_f)
    
    MetricsRegistry.gauge(
      "db.connections.waiting"
    ).set(stats[:waiting].to_f)
  end
  
  # Business metrics
  def self.record_user_action(action : String)
    MetricsRegistry.counter(
      "app.user_actions.total",
      {"action" => action}
    ).increment
  end
  
  def self.record_request(path : String, method : String, status : Int32, duration : Time::Span)
    MetricsRegistry.counter(
      "http.requests.total",
      {"path" => path, "method" => method, "status" => status.to_s}
    ).increment
    
    MetricsRegistry.histogram(
      "http.requests.duration",
      {"path" => path, "method" => method}
    ).observe(duration.total_milliseconds)
  end
  
  # Cache metrics
  def self.record_cache_hit(cache_name : String)
    MetricsRegistry.counter(
      "cache.hits.total",
      {"cache" => cache_name}
    ).increment
  end
  
  def self.record_cache_miss(cache_name : String)
    MetricsRegistry.counter(
      "cache.misses.total",
      {"cache" => cache_name}
    ).increment
  end
end
```

### Metrics Export

```crystal
class PrometheusExporter
  def self.export : String
    lines = [] of String
    
    MetricsRegistry.collect.each do |metric|
      # Convert to Prometheus format
      tags_str = metric[:tags].map { |k, v| "#{k}=\"#{v}\"" }.join(",")
      metric_name = metric[:name].gsub(".", "_")
      
      if tags_str.empty?
        lines << "#{metric_name} #{metric[:value]}"
      else
        lines << "#{metric_name}{#{tags_str}} #{metric[:value]}"
      end
    end
    
    lines.join("\n")
  end
end

class MetricsEndpoint
  def self.handler(context : HTTP::Server::Context)
    context.response.content_type = "text/plain"
    context.response.print PrometheusExporter.export
  end
end

# Mount metrics endpoint
server = HTTP::Server.new do |context|
  if context.request.path == "/metrics"
    MetricsEndpoint.handler(context)
  end
end
```

## Performance Profiling

### CPU Profiling

```crystal
class CPUProfiler
  def self.profile(duration : Time::Span = 30.seconds, &block)
    samples = [] of Sample
    sampling_interval = 10.milliseconds
    stop_profiling = false
    
    # Start sampling thread
    spawn do
      while !stop_profiling
        samples << capture_sample
        sleep sampling_interval
      end
    end
    
    # Run the block
    result = yield
    
    # Stop profiling
    stop_profiling = true
    sleep sampling_interval * 2  # Ensure last sample
    
    # Analyze samples
    report = analyze_samples(samples)
    
    {result: result, profile: report}
  end
  
  struct Sample
    property timestamp : Time
    property stack_trace : Array(String)
    property memory_usage : Int64
    
    def initialize(@timestamp, @stack_trace, @memory_usage)
    end
  end
  
  private def self.capture_sample : Sample
    Sample.new(
      Time.utc,
      caller,
      GC.stats.heap_size
    )
  end
  
  private def self.analyze_samples(samples : Array(Sample))
    # Group by method
    method_times = Hash(String, Int32).new(0)
    
    samples.each do |sample|
      sample.stack_trace.each do |frame|
        method = extract_method_name(frame)
        method_times[method] += 1
      end
    end
    
    # Calculate percentages
    total_samples = samples.size
    method_times.transform_values { |count| (count.to_f / total_samples * 100).round(2) }
               .to_a
               .sort_by { |_, pct| -pct }
               .first(20)
  end
  
  private def self.extract_method_name(frame : String) : String
    # Extract method name from stack frame
    frame.split(" in ").last.split(":").first
  end
end
```

### Memory Profiling

```crystal
class MemoryProfiler
  struct AllocationInfo
    property count : Int32 = 0
    property total_size : Int64 = 0
    property location : String
  end
  
  @@allocations = {} of String => AllocationInfo
  @@enabled = false
  
  def self.start
    @@enabled = true
    @@allocations.clear
    
    # Hook into allocations (pseudo-code, actual implementation varies)
    # GC.on_malloc do |size, location|
    #   track_allocation(size, location) if @@enabled
    # end
  end
  
  def self.stop
    @@enabled = false
  end
  
  def self.report
    @@allocations.values
      .sort_by(&.total_size)
      .reverse
      .first(50)
      .map do |info|
        {
          location: info.location,
          count: info.count,
          total_size: format_bytes(info.total_size),
          avg_size: format_bytes(info.total_size / info.count)
        }
      end
  end
  
  private def self.track_allocation(size : Int64, location : String)
    info = @@allocations[location] ||= AllocationInfo.new(location: location)
    info.count += 1
    info.total_size += size
  end
  
  private def self.format_bytes(bytes : Int64) : String
    case bytes
    when .>= 1_073_741_824
      "#{(bytes / 1_073_741_824.0).round(2)} GB"
    when .>= 1_048_576
      "#{(bytes / 1_048_576.0).round(2)} MB"
    when .>= 1024
      "#{(bytes / 1024.0).round(2)} KB"
    else
      "#{bytes} B"
    end
  end
end
```

## Real-Time Monitoring

### Health Checks

```crystal
class HealthCheck
  enum Status
    Healthy
    Degraded
    Unhealthy
  end
  
  struct ComponentHealth
    property name : String
    property status : Status
    property message : String?
    property latency : Time::Span?
    property metadata : Hash(String, String)
    
    def initialize(@name, @status, @message = nil, @latency = nil, @metadata = {} of String => String)
    end
  end
  
  def self.check_all : NamedTuple(status: Status, components: Array(ComponentHealth))
    components = [] of ComponentHealth
    
    # Database health
    components << check_database
    
    # Cache health
    components << check_cache
    
    # Queue health
    components << check_queue
    
    # External services
    components << check_external_services
    
    # Overall status
    overall_status = if components.all?(&.status.healthy?)
      Status::Healthy
    elsif components.any?(&.status.unhealthy?)
      Status::Unhealthy
    else
      Status::Degraded
    end
    
    {status: overall_status, components: components}
  end
  
  private def self.check_database : ComponentHealth
    start = Time.monotonic
    
    Grant.connection.scalar("SELECT 1")
    latency = Time.monotonic - start
    
    status = case latency
    when .< 10.milliseconds
      Status::Healthy
    when .< 100.milliseconds
      Status::Degraded
    else
      Status::Unhealthy
    end
    
    ComponentHealth.new(
      "database",
      status,
      latency: latency,
      metadata: {"latency_ms" => latency.total_milliseconds.to_s}
    )
  rescue ex
    ComponentHealth.new(
      "database",
      Status::Unhealthy,
      message: ex.message
    )
  end
  
  private def self.check_cache : ComponentHealth
    # Implementation
    ComponentHealth.new("cache", Status::Healthy)
  end
  
  private def self.check_queue : ComponentHealth
    # Implementation
    ComponentHealth.new("queue", Status::Healthy)
  end
  
  private def self.check_external_services : ComponentHealth
    # Implementation
    ComponentHealth.new("external_services", Status::Healthy)
  end
end
```

### Dashboard Data

```crystal
class MonitoringDashboard
  def self.snapshot
    {
      timestamp: Time.utc,
      health: HealthCheck.check_all,
      metrics: current_metrics,
      active_queries: active_queries,
      slow_queries: recent_slow_queries,
      error_rate: calculate_error_rate,
      throughput: calculate_throughput
    }
  end
  
  private def self.current_metrics
    {
      database: {
        active_connections: connection_pool.active_count,
        idle_connections: connection_pool.idle_count,
        query_count: QueryAnalyzer.report.sum(&.count),
        avg_query_time: QueryAnalyzer.report.sum(&.avg_time) / QueryAnalyzer.report.size
      },
      application: {
        request_count: MetricsRegistry.counter("http.requests.total").value,
        error_count: MetricsRegistry.counter("http.requests.total", {"status" => "500"}).value,
        avg_response_time: MetricsRegistry.histogram("http.requests.duration").percentile(0.5)
      },
      system: {
        memory_usage: GC.stats.heap_size,
        fiber_count: Fiber.count,
        cpu_usage: Process.cpu_usage
      }
    }
  end
  
  private def self.active_queries
    Grant.connection.query("SELECT * FROM pg_stat_activity WHERE state = 'active'").to_a
  end
  
  private def self.recent_slow_queries
    QueryAnalyzer.slow_queries.first(10)
  end
  
  private def self.calculate_error_rate : Float64
    total = MetricsRegistry.counter("http.requests.total").value
    errors = MetricsRegistry.counter("http.requests.total", {"status" => "500"}).value
    
    return 0.0 if total == 0
    (errors / total * 100).round(2)
  end
  
  private def self.calculate_throughput : Float64
    # Requests per second over last minute
    MetricsRegistry.counter("http.requests.total").value / 60.0
  end
end
```

## Alerting

### Alert Manager

```crystal
class AlertManager
  enum Severity
    Info
    Warning
    Error
    Critical
  end
  
  struct Alert
    property name : String
    property severity : Severity
    property message : String
    property metadata : Hash(String, String)
    property timestamp : Time
    property resolved : Bool = false
    
    def initialize(@name, @severity, @message, @metadata = {} of String => String)
      @timestamp = Time.utc
    end
  end
  
  @@alerts = [] of Alert
  @@handlers = [] of Proc(Alert, Nil)
  
  def self.trigger(name : String, severity : Severity, message : String, metadata = {} of String => String)
    alert = Alert.new(name, severity, message, metadata)
    
    @@alerts << alert
    
    # Notify handlers
    @@handlers.each do |handler|
      spawn { handler.call(alert) }
    end
    
    # Log alert
    Log.for("alerts").error { alert.to_h }
    
    alert
  end
  
  def self.on_alert(&block : Alert -> Nil)
    @@handlers << block
  end
  
  def self.check_thresholds
    # Database connection pool
    if connection_pool.available_count < 2
      trigger(
        "low_connection_pool",
        Severity::Warning,
        "Database connection pool running low",
        {"available" => connection_pool.available_count.to_s}
      )
    end
    
    # Error rate
    error_rate = MonitoringDashboard.calculate_error_rate
    if error_rate > 5.0
      trigger(
        "high_error_rate",
        Severity::Error,
        "Error rate exceeds threshold",
        {"rate" => error_rate.to_s}
      )
    end
    
    # Response time
    p95_response_time = MetricsRegistry.histogram("http.requests.duration").percentile(0.95)
    if p95_response_time > 1000.0
      trigger(
        "slow_response_time",
        Severity::Warning,
        "95th percentile response time exceeds 1s",
        {"p95_ms" => p95_response_time.to_s}
      )
    end
  end
end

# Configure alert handlers
AlertManager.on_alert do |alert|
  case alert.severity
  when .critical?, .error?
    # Send to PagerDuty
    PagerDuty.trigger(alert)
  when .warning?
    # Send to Slack
    Slack.notify(alert)
  end
end
```

## Distributed Tracing

```crystal
class DistributedTracing
  struct Span
    property trace_id : String
    property span_id : String
    property parent_span_id : String?
    property operation : String
    property start_time : Time
    property end_time : Time?
    property tags : Hash(String, String)
    property logs : Array(NamedTuple(timestamp: Time, message: String))
    
    def initialize(@trace_id, @operation, @parent_span_id = nil)
      @span_id = Random::Secure.hex(8)
      @start_time = Time.utc
      @tags = {} of String => String
      @logs = [] of NamedTuple(timestamp: Time, message: String)
    end
    
    def finish
      @end_time = Time.utc
    end
    
    def duration : Time::Span?
      return nil unless end_time
      end_time.not_nil! - start_time
    end
  end
  
  class_property current_span : Span?
  
  def self.start_span(operation : String, parent : Span? = current_span) : Span
    trace_id = parent?.trace_id || Random::Secure.hex(16)
    span = Span.new(trace_id, operation, parent?.span_id)
    
    self.current_span = span
    span
  end
  
  def self.with_span(operation : String, &block)
    span = start_span(operation)
    
    begin
      result = yield span
      span.tags["status"] = "success"
      result
    rescue ex
      span.tags["status"] = "error"
      span.tags["error.message"] = ex.message || ""
      span.logs << {timestamp: Time.utc, message: ex.inspect_with_backtrace}
      raise ex
    ensure
      span.finish
      export_span(span)
      self.current_span = span.parent_span_id ? find_parent(span) : nil
    end
  end
  
  private def self.export_span(span : Span)
    # Export to tracing backend (Jaeger, Zipkin, etc.)
    spawn do
      HTTP::Client.post(
        ENV["TRACING_ENDPOINT"],
        headers: HTTP::Headers{"Content-Type" => "application/json"},
        body: span.to_json
      )
    end
  end
end

# Usage
DistributedTracing.with_span("http.request") do |span|
  span.tags["http.method"] = "GET"
  span.tags["http.path"] = "/api/users"
  
  DistributedTracing.with_span("db.query") do |db_span|
    db_span.tags["db.statement"] = "SELECT * FROM users"
    User.all.to_a
  end
end
```

## Testing and Debugging

```crystal
describe "Performance Monitoring" do
  it "tracks query performance" do
    10.times { User.find(1) }
    
    stats = QueryAnalyzer.report
    stats.should_not be_empty
    
    user_query = stats.find { |s| s.sql.includes?("users") }
    user_query.not_nil!.count.should eq(10)
  end
  
  it "detects slow queries" do
    # Simulate slow query
    Grant.connection.exec("SELECT pg_sleep(0.2)")
    
    slow_queries = QueryAnalyzer.slow_queries(threshold: 100.milliseconds)
    slow_queries.should_not be_empty
  end
  
  it "collects metrics" do
    ApplicationMetrics.record_user_action("login")
    ApplicationMetrics.record_user_action("login")
    
    counter = MetricsRegistry.counter("app.user_actions.total", {"action" => "login"})
    counter.value.should eq(2.0)
  end
end
```

## Best Practices

### 1. Use Structured Logging
```crystal
Log.info do
  {
    event: "user_action",
    user_id: user.id,
    action: "purchase",
    amount: order.total,
    duration_ms: elapsed.total_milliseconds
  }
end
```

### 2. Monitor Key Metrics
```crystal
# Track business metrics
MetricsRegistry.counter("orders.completed").increment
MetricsRegistry.gauge("inventory.available").set(count)
MetricsRegistry.histogram("payment.processing_time").observe(duration)
```

### 3. Set Up Alerts
```crystal
# Define alert thresholds
if error_rate > 1.0
  AlertManager.trigger(
    "high_error_rate",
    AlertManager::Severity::Warning,
    "Error rate above 1%"
  )
end
```

## Next Steps

- [Database Scaling](database-scaling.md)
- [Async and Concurrency](async-concurrency.md)
- [Transactions and Locking](transactions-and-locking.md)
- [Query Optimization](../advanced/performance/query-optimization.md)