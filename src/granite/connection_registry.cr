module Granite
  # Registry for managing database connections and adapters
  # This works alongside the existing Granite::Connections system
  class ConnectionRegistry
    # Connection specification
    struct ConnectionSpec
      property database : String
      property adapter_class : Adapter::Base.class
      property url : String
      property role : Symbol
      property shard : Symbol?
      # Pool config removed - using crystal-db built-in pooling
      
      def initialize(@database, @adapter_class, @url, @role, @shard = nil)
      end
      
      def connection_key : String
        if shard
          "#{database}:#{role}:#{shard}"
        else
          "#{database}:#{role}"
        end
      end
    end
    
    # Class-level storage
    @@adapters = {} of String => Adapter::Base
    @@specifications = {} of String => ConnectionSpec
    @@mutex = Mutex.new
    @@default_database : String? = nil
    
    # Establish a new connection
    def self.establish_connection(
      database : String,
      adapter : Adapter::Base.class,
      url : String,
      role : Symbol = :primary,
      shard : Symbol? = nil
    )
      spec = ConnectionSpec.new(database, adapter, url, role, shard)
      key = spec.connection_key
      
      @@mutex.synchronize do
        # Store specification
        @@specifications[key] = spec
        
        # Create adapter instance
        adapter_instance = adapter.new(key, url)
        @@adapters[key] = adapter_instance
        
        # TODO: Register with the old system for backward compatibility
        # Temporarily disabled due to conflicts in tests
        
        # Set as default if first database
        @@default_database ||= database
        
        # Connection established successfully
      end
    end
    
    # Register multiple connections at once
    def self.establish_connections(config : Hash(String, NamedTuple))
      config.each do |database, settings|
        # Extract settings with defaults
        adapter = settings[:adapter].as(Adapter::Base.class)
        
        # Handle writer connection
        if writer_url = settings[:writer]?.as?(String)
          establish_connection(
            database: database,
            adapter: adapter,
            url: writer_url,
            role: :writing
          )
        end
        
        # Handle reader connection
        if reader_url = settings[:reader]?.as?(String)
          establish_connection(
            database: database,
            adapter: adapter,
            url: reader_url,
            role: :reading
          )
        end
        
        # Handle single connection (no reader/writer split)
        if url = settings[:url]?.as?(String)
          establish_connection(
            database: database,
            adapter: adapter,
            url: url,
            role: :primary
          )
        end
      end
    end
    
    # Get an adapter
    def self.get_adapter(database : String, role : Symbol = :primary, shard : Symbol? = nil) : Adapter::Base
      key = if shard
        "#{database}:#{role}:#{shard}"
      else
        "#{database}:#{role}"
      end
      
      @@mutex.synchronize do
        adapter = @@adapters[key]?
        
        # Fallback to primary role if specific role not found
        if adapter.nil? && role != :primary
          key = shard ? "#{database}:primary:#{shard}" : "#{database}:primary"
          adapter = @@adapters[key]?
        end
        
        # Fallback to writer if reading not available
        if adapter.nil? && role == :reading
          key = shard ? "#{database}:writing:#{shard}" : "#{database}:writing"
          adapter = @@adapters[key]?
        end
        
        adapter || raise "No adapter found for #{key}"
      end
    end
    
    # Execute with a specific adapter
    def self.with_adapter(database : String, role : Symbol = :primary, shard : Symbol? = nil, &)
      adapter = get_adapter(database, role, shard)
      yield adapter
    end
    
    # Get all adapters for a database
    def self.adapters_for_database(database : String) : Array(Adapter::Base)
      @@mutex.synchronize do
        @@adapters.select { |key, _| key.starts_with?("#{database}:") }.values
      end
    end
    
    # Get adapter names
    def self.adapter_names : Array(String)
      @@mutex.synchronize do
        @@adapters.keys
      end
    end
    
    # Clear all adapters
    def self.clear_all
      @@mutex.synchronize do
        @@adapters.clear
        @@specifications.clear
        @@default_database = nil
      end
      
      # All adapters cleared
    end
    
    # Get default database name
    def self.default_database : String
      @@default_database || raise "No default database configured"
    end
    
    # Set default database
    def self.default_database=(name : String)
      @@default_database = name
    end
    
    # Check if a connection exists
    def self.connection_exists?(database : String, role : Symbol = :primary, shard : Symbol? = nil) : Bool
      key = shard ? "#{database}:#{role}:#{shard}" : "#{database}:#{role}"
      @@mutex.synchronize { @@adapters.has_key?(key) }
    end
    
    # Get all registered databases
    def self.databases : Array(String)
      @@mutex.synchronize do
        @@specifications.values.map(&.database).uniq
      end
    end
    
    # Get all shards for a database
    def self.shards_for_database(database : String) : Array(Symbol)
      @@mutex.synchronize do
        @@specifications.values
          .select { |spec| spec.database == database && spec.shard }
          .map(&.shard.not_nil!)
          .uniq
      end
    end
    
    # Pool configuration is now handled by crystal-db URL parameters
  end
end