require "./connection_registry"

# Connection management is now built into Granite::Base
# This provides multiple database support, sharding, and role-based connections
module Granite::ConnectionManagement
  # Connection context for tracking current database/role/shard
  struct ConnectionContext
    property database : String
    property role : Symbol
    property shard : Symbol?
    property prevent_writes : Bool
    
    def initialize(@database, @role = :primary, @shard = nil, @prevent_writes = false)
    end
  end
  
  macro included
    # Connection configuration
    class_property database_name : String = "primary"
    class_property connection_config = {} of Symbol => String
    class_property shard_config = {} of Symbol => Hash(Symbol, String)
    
    # Thread-local connection context
    class_property connection_context : ConnectionContext?
    
    # Track last write time for read/write splitting
    class_property last_write_time : Time::Span = Time.monotonic
    class_property read_delay : Time::Span = 2.seconds
  end
  
  # DSL for configuring connections
  macro connects_to(database = nil, config = nil, shards = nil)
    {% if database %}
      self.database_name = {{database}}
    {% end %}
    
    {% if config %}
      {% if config.is_a?(NamedTupleLiteral) %}
        self.connection_config = {
          {% for role, db_name in config %}
            {{role.id.symbolize}} => {{db_name.id.stringify}},
          {% end %}
        } of Symbol => String
      {% end %}
    {% end %}
    
    {% if shards %}
      {% if shards.is_a?(NamedTupleLiteral) %}
        self.shard_config = {
          {% for shard_name, shard_settings in shards %}
            {{shard_name.id.symbolize}} => {
              {% for role, db_name in shard_settings %}
                {{role.id.symbolize}} => {{db_name.id.stringify}},
              {% end %}
            } of Symbol => String,
          {% end %}
        } of Symbol => Hash(Symbol, String)
      {% end %}
    {% end %}
  end
  
  module ClassMethods
    # Switch connection for a block
    def connected_to(
      database : String? = nil,
      role : Symbol? = nil,
      shard : Symbol? = nil,
      prevent_writes : Bool = false,
      &
    )
      # Save current context
      previous_context = connection_context
      previous_database = database_name if database
      
      # Create new context
      self.connection_context = ConnectionContext.new(
        database || current_database,
        role || current_role,
        shard || current_shard,
        prevent_writes || preventing_writes?
      )
      
      # Update database name if provided
      self.database_name = database if database
      
      yield
    ensure
      # Restore previous context
      self.connection_context = previous_context
      self.database_name = previous_database if database && previous_database
    end
    
    # Get current database
    def current_database : String
      connection_context.try(&.database) || database_name
    end
    
    # Get current role
    def current_role : Symbol
      return :reading if should_use_reader?
      connection_context.try(&.role) || :primary
    end
    
    # Get current shard
    def current_shard : Symbol?
      connection_context.try(&.shard)
    end
    
    # Check if currently preventing writes
    def preventing_writes? : Bool
      connection_context.try(&.prevent_writes) || false
    end
    
    # Block writes for a block
    def while_preventing_writes(&)
      connected_to(prevent_writes: true) do
        yield
      end
    end
    
    # Get the current adapter
    def adapter : Adapter::Base
      # Determine database name
      db_name = if shard = current_shard
        # For sharded connections, look up the database name
        shard_settings = shard_config[shard]?
        shard_settings.try(&.[current_role]?) || current_database
      elsif role_db = connection_config[current_role]?
        # For role-based connections
        role_db
      else
        # Default database
        current_database
      end
      
      begin
        ConnectionRegistry.get_adapter(db_name, current_role, current_shard)
      rescue
        # Fallback to first registered connection for backward compatibility
        # This handles cases where models haven't configured connections yet
        if reg = Granite::Connections.registered_connections
          if conn = reg.first?
            conn[:writer]
          else
            raise "No database connection configured. Please use Granite::ConnectionRegistry.establish_connection"
          end
        else
          raise "No database connection configured. Please use Granite::ConnectionRegistry.establish_connection"
        end
      end
    end
    
    # Mark write operation
    def mark_write_operation
      self.last_write_time = Time.monotonic
    end
    
    # Check if should use reader
    private def should_use_reader? : Bool
      # Only use reader if:
      # 1. We have a reading role configured
      # 2. Enough time has passed since last write
      # 3. We're not explicitly using a different role
      return false unless connection_config.has_key?(:reading)
      return false if connection_context.try(&.role)
      
      Time.monotonic - last_write_time > read_delay
    end
  end
  
  # Legacy support - will be removed
  macro connection(name)
    self.database_name = {{name.id.stringify}}
  end
  
  macro included
    extend ClassMethods
  end
end
