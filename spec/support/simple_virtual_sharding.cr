require "../../src/grant"
require "../../src/grant/sharding"

module Grant::Testing
  # Simplified virtual sharding for tests
  class VirtualShardAdapter < Grant::Adapter::Base
    QUOTING_CHAR = '"'

    @@shard_queries = {} of Symbol => Array(String)

    getter shard : Symbol
    getter url : String
    getter name : String

    def initialize(@name : String, @url : String)
      # Extract shard from URL. Stop at the first '?' so pool query params that
      # ConnectionRegistry appends (e.g. "?max_pool_size=25&...") don't end up
      # in the captured shard name and force every adapter to :default.
      if match = @url.match(/virtual:\/\/([^?]+)/)
        shard_name = match[1]
        # Convert known shard names to symbols
        @shard = case shard_name
                 when "shard_0"          then :shard_0
                 when "shard_1"          then :shard_1
                 when "shard_2"          then :shard_2
                 when "shard_3"          then :shard_3
                 when "shard_4"          then :shard_4
                 when "shard_5"          then :shard_5
                 when "shard_6"          then :shard_6
                 when "shard_7"          then :shard_7
                 when "shard_8"          then :shard_8
                 when "shard_9"          then :shard_9
                 when "shard_2023"       then :shard_2023
                 when "shard_2024_h1"    then :shard_2024_h1
                 when "shard_2024_h2"    then :shard_2024_h2
                 when "shard_current"    then :shard_current
                 when "shard_old"        then :shard_old
                 when "shard_medium"     then :shard_medium
                 when "shard_us_west"    then :shard_us_west
                 when "shard_us_east"    then :shard_us_east
                 when "shard_us_central" then :shard_us_central
                 when "shard_eu"         then :shard_eu
                 when "shard_apac"       then :shard_apac
                 when "shard_asia"       then :shard_asia
                 when "shard_global"     then :shard_global
                 when "shard_us"         then :shard_us
                 when "shard_other"      then :shard_other
                 else                         :default
                 end
      else
        @shard = :default
      end

      # Don't call super - we'll handle everything ourselves
      @@shard_queries[@shard] ||= [] of String
    end

    # Override open to not actually open a database connection. Grant passes
    # the statement, binds and model name, so match the full signature.
    def open(sql : String? = nil, binds = nil, name : String? = nil, &)
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

    def scalar(query : String, *args) : DB::Any
      track_query(query)
      1_i64
    end

    def scalar(query : String, args : Enumerable) : DB::Any
      track_query(query)
      1_i64
    end

    # query_one (non-nilable) variant — always raises since no real DB backing
    def query_one(query : String, *args, as types : Tuple)
      raise DB::Error.new("VirtualShardAdapter: query_one not supported")
    end

    def query_one(query : String, *args, as type : T.class) : T forall T
      raise DB::Error.new("VirtualShardAdapter: query_one not supported")
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

    # Positional binds, as DB::Connection#query takes them.
    def query(query : String, *args, &)
      track_query(query)
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

    # Positional binds, as DB::Connection#exec takes them.
    def exec(query : String, *args) : DB::ExecResult
      track_query(query)
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

    def select(query : Grant::Select::Container, clause = "", params = [] of Grant::Columns::Type, &)
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

    def query_one?(statement : String, args = [] of Grant::Columns::Type, as type : T.class = Bool) : T? forall T
      track_query(statement)
      nil # Always return nil for testing
    end

    def exists?(table_name : String, criteria : String, params = [] of Grant::Columns::Type) : Bool
      statement = "SELECT EXISTS(SELECT 1 FROM #{table_name} WHERE #{criteria})"
      track_query(statement)
      false # Always return false for testing
    end

    def insert(table_name : String, fields, params, lastval) : Int64
      field_names = fields.join(", ")
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

    def supports_lock_mode?(mode : Grant::Locking::LockMode) : Bool
      false
    end

    def supports_isolation_level?(level : Grant::Transaction::IsolationLevel) : Bool
      false
    end

    def supports_savepoints? : Bool
      false
    end
  end

  # Simplified test helpers
  module ShardingHelpers
    GENERIC_SHARDS = [:shard_0, :shard_1, :shard_2, :shard_3, :shard_4,
                      :shard_5, :shard_6, :shard_7, :shard_8, :shard_9]

    def with_virtual_shards(count : Int32, &block)
      unless count > 0 && count <= GENERIC_SHARDS.size
        raise "Unsupported virtual shard count: #{count}. Supported: 1-#{GENERIC_SHARDS.size}"
      end

      with_virtual_shards(GENERIC_SHARDS.first(count), &block)
    end

    def with_virtual_shards(shards : Array(Symbol), &block)
      VirtualShardAdapter.clear_all
      Grant::HealthMonitor.test_mode = true

      begin
        # Register the exact shard names from the model's resolver.
        shards.each do |shard|
          Grant::ConnectionRegistry.establish_connection(
            database: "test",
            adapter: VirtualShardAdapter,
            url: "virtual://#{shard}",
            role: :primary,
            shard: shard
          )
        end

        # Don't do anything here - let the model register itself

        yield
      ensure
        Grant::ConnectionRegistry.clear_all
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
