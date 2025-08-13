require "../../src/grant"
require "../../src/grant/sharding"

module Grant::Testing
  # Mock database that stores data in memory
  class MockDatabase
    alias Row = Hash(String, DB::Any)
    alias Table = Hash(DB::Any, Row)
    
    def initialize
      @tables = {} of String => Table
      @query_log = [] of NamedTuple(query: String, params: Array(Grant::Columns::Type))
    end
    
    def execute_query(query : String, params : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : Array(Row)
      @query_log << {query: query, params: params}
      
      # Simple query parsing - this is just for testing
      case query
      when /^SELECT .* FROM (\w+)/
        table_name = $1
        table = @tables[table_name]? || Table.new
        
        # Apply WHERE clause if present
        if query =~ /WHERE (.+)/
          where_clause = $1
          # Very simple WHERE parsing for testing
          if where_clause =~ /(\w+)\s*=\s*\?/
            field = $1
            value = params[0]?
            
            table.values.select do |row|
              row[field]? == value
            end
          else
            table.values.to_a
          end
        else
          table.values.to_a
        end
      when /^INSERT INTO (\w+) \((.*?)\) VALUES \((.*?)\)/
        table_name = $1
        fields = $2.split(",").map(&.strip)
        
        # Create table if it doesn't exist
        table = @tables[table_name] ||= Table.new
        
        # Create row
        row = Row.new
        fields.each_with_index do |field, i|
          row[field] = params[i]? || nil
        end
        
        # Generate ID if needed
        if !row.has_key?("id") || row["id"].nil?
          row["id"] = (table.size + 1).to_i64
        end
        
        table[row["id"].not_nil!] = row
        
        [{} of String => DB::Any] # Return empty result for INSERT
      when /^UPDATE (\w+) SET (.*) WHERE (.*)/
        table_name = $1
        table = @tables[table_name]? || Table.new
        
        # Very simple UPDATE - just for testing
        [] of Row
      when /^DELETE FROM (\w+)/
        table_name = $1
        @tables[table_name] = Table.new
        [] of Row
      else
        [] of Row
      end
    end
    
    def query_log
      @query_log
    end
    
    def clear
      @tables.clear
      @query_log.clear
    end
    
    def insert_row(table_name : String, row : Row)
      table = @tables[table_name] ||= Table.new
      id = row["id"]? || (table.size + 1).to_i64
      row["id"] = id
      table[id] = row
    end
  end
  
  # Virtual adapter that routes queries to mock databases per shard
  class VirtualShardAdapter < Grant::Adapter::Base
    QUOTING_CHAR = '"'
    
    @@shards = {} of Symbol => MockDatabase
    @@query_tracking = {} of Symbol => Array(String)
    
    getter shard : Symbol
    getter base_adapter : Grant::Adapter::Base
    
    def initialize(@shard : Symbol, @base_adapter : Grant::Adapter::Base)
      super("virtual_#{@shard}", "virtual://#{@shard}")
      @@shards[@shard] ||= MockDatabase.new
    end
    
    def self.shards
      @@shards
    end
    
    def self.clear_all
      @@shards.clear
      @@query_tracking.clear
    end
    
    def self.query_log(shard : Symbol) : Array(NamedTuple(query: String, params: Array(Grant::Columns::Type)))
      @@shards[shard]?.try(&.query_log) || [] of NamedTuple(query: String, params: Array(Grant::Columns::Type))
    end
    
    def clear(table_name : String)
      mock_db.execute_query("DELETE FROM #{table_name}")
    end
    
    def select(query : Grant::Select::Container, clause = "", params = [] of Grant::Columns::Type, &)
      statement = String.build do |stmt|
        stmt << "SELECT "
        stmt << query.fields.join(", ")
        stmt << " FROM #{query.table_name} #{clause}"
      end
      
      track_query(@shard, statement)
      
      # Execute on mock database
      rows = mock_db.execute_query(statement, params.map(&.as(Grant::Columns::Type)))
      
      # Convert to result set format
      # This is a simplified mock - real implementation would use DB::ResultSet
      rows.each do |row|
        yield MockResultSet.new(row, query.fields)
      end
    end
    
    def query_one?(statement : String, args = [] of Grant::Columns::Type, as type = Bool) : Bool?
      track_query(@shard, statement)
      false # Always return false for testing
    end
    
    def exists?(table_name : String, criteria : String, params = [] of Grant::Columns::Type) : Bool
      statement = "SELECT EXISTS(SELECT 1 FROM #{table_name} WHERE #{criteria})"
      track_query(@shard, statement)
      
      rows = mock_db.execute_query("SELECT * FROM #{table_name} WHERE #{criteria}", params.map(&.as(Grant::Columns::Type)))
      !rows.empty?
    end
    
    def insert(table_name : String, fields, params, lastval) : Int64
      field_names = fields.map { |f| f[:name] }.join(", ")
      placeholders = fields.map { "?" }.join(", ")
      statement = "INSERT INTO #{table_name} (#{field_names}) VALUES (#{placeholders})"
      
      track_query(@shard, statement)
      
      # Create row for mock database
      row = {} of String => DB::Any
      fields.each_with_index do |field, i|
        row[field[:name]] = params[i]?
      end
      
      # Insert and get ID
      mock_db.insert_row(table_name, row)
      row["id"].as(Int64)
    end
    
    def import(table_name : String, primary_name : String, auto : Bool, fields, model_array, **options)
      model_array.each do |model|
        params = fields.map { |f| model.read_attribute(f[:name]) }
        insert(table_name, fields, params, nil)
      end
    end
    
    def update(table_name : String, primary_name : String, fields, params)
      set_clause = fields.map { |f| "#{f[:name]} = ?" }.join(", ")
      statement = "UPDATE #{table_name} SET #{set_clause} WHERE #{primary_name} = ?"
      
      track_query(@shard, statement)
      
      # Mock update
      mock_db.execute_query(statement, params.map(&.as(Grant::Columns::Type)))
    end
    
    def delete(table_name : String, primary_name : String, value)
      statement = "DELETE FROM #{table_name} WHERE #{primary_name} = ?"
      track_query(@shard, statement)
      
      mock_db.execute_query(statement, [value.as(Grant::Columns::Type)])
    end
    
    private def mock_db : MockDatabase
      @@shards[@shard]
    end
    
    private def track_query(shard : Symbol, query : String)
      @@query_tracking[shard] ||= [] of String
      @@query_tracking[shard] << query
    end
    
    # Quote implementation
    def quote(name : String) : String
      "#{QUOTING_CHAR}#{name}#{QUOTING_CHAR}"
    end
    
    # Implement abstract method for lock mode support
    def supports_lock_mode?(mode : Grant::Locking::LockMode) : Bool
      # Virtual adapter doesn't support locks
      false
    end
    
    # Implement abstract method for isolation level support
    def supports_isolation_level?(level : Grant::Transaction::IsolationLevel) : Bool
      # Virtual adapter doesn't support isolation levels
      false
    end
    
    # Implement abstract method for savepoint support
    def supports_savepoints? : Bool
      # Virtual adapter doesn't support savepoints
      false
    end
  end
  
  # Mock result set for testing
  class MockResultSet
    def initialize(@row : Hash(String, DB::Any), @fields : Array(String))
      @index = 0
    end
    
    def read(type : T.class) : T forall T
      field = @fields[@index]
      @index += 1
      
      value = @row[field]?
      
      # Type conversion
      case value
      when T
        value
      when Nil
        nil.as(T)
      when Int32
        value.to_i64.as(T) if T == Int64
      else
        value.as(T)
      end
    end
    
    def read(type : T.class | Nil) : T? forall T
      read(T)
    end
  end
  
  # Test helpers for virtual sharding
  module ShardingHelpers
    def with_virtual_shards(count : Int32, &block)
      # Clear any existing virtual shards
      VirtualShardAdapter.clear_all
      
      # Set up test mode
      original_test_mode = Grant::HealthMonitor.test_mode
      Grant::HealthMonitor.test_mode = true
      
      begin
        # Create virtual shards
        (0...count).each do |i|
          shard_name = :"shard_#{i}"
          
          # Create a base adapter (we'll use the virtual one)
          base_adapter = Grant::Adapter::Sqlite.new("test", ":memory:")
          adapter = VirtualShardAdapter.new(shard_name, base_adapter)
          
          # Register with ConnectionRegistry
          Grant::ConnectionRegistry.establish_connection(
            database: "test",
            adapter: VirtualShardAdapter,
            url: "virtual://#{shard_name}",
            role: :primary,
            shard: shard_name
          )
        end
        
        yield
      ensure
        # Cleanup
        Grant::ConnectionRegistry.clear_all
        Grant::ShardManager.clear
        VirtualShardAdapter.clear_all
        Grant::HealthMonitor.test_mode = original_test_mode
      end
    end
    
    def track_shard_queries(&block)
      initial_logs = {} of Symbol => Array(NamedTuple(query: String, params: Array(Grant::Columns::Type)))
      
      VirtualShardAdapter.shards.each do |shard, _|
        initial_logs[shard] = VirtualShardAdapter.query_log(shard).dup
      end
      
      yield
      
      # Return queries executed during block
      queries_by_shard = {} of Symbol => Array(String)
      
      VirtualShardAdapter.shards.each do |shard, _|
        current_log = VirtualShardAdapter.query_log(shard)
        initial_count = initial_logs[shard]?.try(&.size) || 0
        
        new_queries = current_log[initial_count..-1].map(&.[:query])
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
    
    # Helper to create test data across shards
    def create_distributed_records(model_class, count : Int32, **attributes)
      records = [] of Grant::Base
      
      count.times do |i|
        attrs = attributes.merge({id: i + 1})
        record = model_class.new(attrs)
        
        # Determine shard and save
        shard = record.determine_shard
        Grant::ShardManager.with_shard(shard) do
          # Manually insert into virtual shard
          adapter = Grant::ConnectionRegistry.get_adapter("test", :primary, shard)
          if adapter.is_a?(VirtualShardAdapter)
            row = {} of String => DB::Any
            attrs.each do |k, v|
              row[k.to_s] = v.as(DB::Any)
            end
            VirtualShardAdapter.shards[shard].insert_row(model_class.table_name, row)
          end
        end
        
        records << record
      end
      
      records
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
    
    def total_queries : Int32
      @queries_by_shard.values.map(&.size).sum
    end
  end
end