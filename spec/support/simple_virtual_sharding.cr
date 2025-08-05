require "../../src/granite"
require "../../src/granite/sharding"

module Granite::Testing
  # Simplified virtual sharding for tests
  class VirtualShardAdapter < Granite::Adapter::Base
    QUOTING_CHAR = '"'
    
    @@shard_queries = {} of Symbol => Array(String)
    
    getter shard : Symbol
    getter url : String
    getter name : String
    
    def initialize(@name : String, @url : String)
      # Extract shard from URL
      if match = @url.match(/virtual:\/\/(.+)/)
        shard_name = match[1]
        # Convert known shard names to symbols
        @shard = case shard_name
        when "shard_0" then :shard_0
        when "shard_1" then :shard_1
        when "shard_2" then :shard_2
        when "shard_3" then :shard_3
        when "shard_4" then :shard_4
        when "shard_5" then :shard_5
        when "shard_6" then :shard_6
        when "shard_7" then :shard_7
        when "shard_8" then :shard_8
        when "shard_9" then :shard_9
        else :default
        end
      else
        @shard = :default
      end
      
      # Don't call super - we'll handle everything ourselves
      @@shard_queries[@shard] ||= [] of String
    end
    
    # Override open to not actually open a database connection
    def open(&)
      # Virtual adapter doesn't need real connections
      yield self
    end
    
    # Override close
    def close
      # Nothing to close
    end
    
    # Health check support
    def scalar(query : String) : DB::Any
      track_query(query)
      # Return 1 for health checks
      1_i64
    end
    
    # Query support for executors
    def query(query : String, args : Enumerable, &)
      track_query(query)
      # Virtual adapter doesn't yield any results
      # This simulates an empty result set
    end
    
    def query(query : String, &)
      track_query(query)
      # Virtual adapter doesn't yield any results
    end
    
    # Exec support for non-select queries
    def exec(query : String) : DB::ExecResult
      track_query(query)
      # Return mock result
      DB::ExecResult.new(0_i64, 0_i64)
    end
    
    def exec(query : String, args : Enumerable) : DB::ExecResult
      track_query(query)
      # Return mock result
      DB::ExecResult.new(0_i64, 0_i64)
    end
    
    def self.shard_queries
      @@shard_queries
    end
    
    def self.clear_all
      @@shard_queries.clear
    end
    
    # Track queries for testing
    private def track_query(query : String)
      @@shard_queries[@shard] << query
    end
    
    # Minimal implementations for testing
    def clear(table_name : String)
      track_query("DELETE FROM #{table_name}")
    end
    
    def select(query : Granite::Select::Container, clause = "", params = [] of Granite::Columns::Type, &)
      statement = String.build do |stmt|
        stmt << "SELECT "
        stmt << query.fields.join(", ")
        stmt << " FROM #{query.table_name} #{clause}"
      end
      
      track_query(statement)
      
      # Virtual adapter doesn't actually query a database
      # Just return without yielding any results
      # This simulates an empty result set
    end
    
    def exists?(table_name : String, criteria : String, params = [] of Granite::Columns::Type) : Bool
      statement = "SELECT EXISTS(SELECT 1 FROM #{table_name} WHERE #{criteria})"
      track_query(statement)
      false # Always return false for testing
    end
    
    def insert(table_name : String, fields, params, lastval) : Int64
      field_names = fields.map { |f| f[:name] }.join(", ")
      statement = "INSERT INTO #{table_name} (#{field_names}) VALUES (...)"
      track_query(statement)
      1_i64 # Return dummy ID
    end
    
    def import(table_name : String, primary_name : String, auto : Bool, fields, model_array, **options)
      track_query("BULK INSERT INTO #{table_name}")
    end
    
    def update(table_name : String, primary_name : String, fields, params)
      statement = "UPDATE #{table_name} SET ... WHERE #{primary_name} = ?"
      track_query(statement)
    end
    
    def delete(table_name : String, primary_name : String, value)
      statement = "DELETE FROM #{table_name} WHERE #{primary_name} = ?"
      track_query(statement)
    end
    
    def quote(name : String) : String
      "#{QUOTING_CHAR}#{name}#{QUOTING_CHAR}"
    end
    
    def supports_lock_mode?(mode : Granite::Locking::LockMode) : Bool
      false
    end
    
    def supports_isolation_level?(level : Granite::Transaction::IsolationLevel) : Bool
      false
    end
    
    def supports_savepoints? : Bool
      false
    end
  end
  
  # Simplified test helpers
  module ShardingHelpers
    def with_virtual_shards(count : Int32, &block)
      VirtualShardAdapter.clear_all
      Granite::HealthMonitor.test_mode = true
      
      begin
        # Create virtual shards
        # Crystal doesn't support dynamic symbol creation, so we need to handle known counts
        case count
        when 1
          Granite::ConnectionRegistry.establish_connection(
            database: "test",
            adapter: VirtualShardAdapter,
            url: "virtual://shard_0",
            role: :primary,
            shard: :shard_0
          )
        when 2
          Granite::ConnectionRegistry.establish_connection(
            database: "test",
            adapter: VirtualShardAdapter,
            url: "virtual://shard_0",
            role: :primary,
            shard: :shard_0
          )
          Granite::ConnectionRegistry.establish_connection(
            database: "test",
            adapter: VirtualShardAdapter,
            url: "virtual://shard_1",
            role: :primary,
            shard: :shard_1
          )
        when 4
          Granite::ConnectionRegistry.establish_connection(
            database: "test",
            adapter: VirtualShardAdapter,
            url: "virtual://shard_0",
            role: :primary,
            shard: :shard_0
          )
          Granite::ConnectionRegistry.establish_connection(
            database: "test",
            adapter: VirtualShardAdapter,
            url: "virtual://shard_1",
            role: :primary,
            shard: :shard_1
          )
          Granite::ConnectionRegistry.establish_connection(
            database: "test",
            adapter: VirtualShardAdapter,
            url: "virtual://shard_2",
            role: :primary,
            shard: :shard_2
          )
          Granite::ConnectionRegistry.establish_connection(
            database: "test",
            adapter: VirtualShardAdapter,
            url: "virtual://shard_3",
            role: :primary,
            shard: :shard_3
          )
        else
          raise "Unsupported virtual shard count: #{count}. Supported: 1, 2, 4"
        end
        
        # Don't do anything here - let the model register itself
        
        yield
      ensure
        Granite::ConnectionRegistry.clear_all
        # Don't clear ShardManager - let model configurations persist
        VirtualShardAdapter.clear_all
      end
    end
    
    def track_shard_queries(&block)
      initial_counts = {} of Symbol => Int32
      
      VirtualShardAdapter.shard_queries.each do |shard, queries|
        initial_counts[shard] = queries.size
      end
      
      yield
      
      # Return new queries by shard
      queries_by_shard = {} of Symbol => Array(String)
      
      VirtualShardAdapter.shard_queries.each do |shard, queries|
        initial_count = initial_counts[shard]? || 0
        new_queries = queries[initial_count..-1]
        queries_by_shard[shard] = new_queries if new_queries.any?
      end
      
      QueryLog.new(queries_by_shard)
    end
    
    def assert_queries_on_shard(shard : Symbol, &block)
      query_log = track_shard_queries(&block)
      
      unless query_log.has_queries_on_shard?(shard)
        raise "Expected queries on #{shard}, but none were executed"
      end
      
      query_log
    end
  end
  
  # Query log for assertions
  class QueryLog
    def initialize(@queries_by_shard : Hash(Symbol, Array(String)))
    end
    
    def has_queries_on_shard?(shard : Symbol) : Bool
      @queries_by_shard.has_key?(shard) && @queries_by_shard[shard].any?
    end
    
    def shards_accessed : Array(Symbol)
      @queries_by_shard.keys
    end
    
    def queries_on_shard(shard : Symbol) : Array(String)
      @queries_by_shard[shard]? || [] of String
    end
  end
end