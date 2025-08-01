require "./connection_handling"

# New connection management module that bridges the old and new systems
module Granite::ConnectionManagementV2
  include ConnectionHandling
  
  macro included
    # Maintain backward compatibility with existing API
    class_property connection_switch_wait_period : Int32 = 2000
    
    # Adapter is now directly available through ConnectionHandling
    # These methods provide backward compatibility
    
    # Override adapter setter to establish connection in new system
    def self.writer_adapter=(adapter : Granite::Adapter::Base)
      # Extract connection info from adapter and register with new system
      ConnectionRegistry.establish_connection(
        database: database_name,
        adapter: adapter.class,
        url: adapter.url,
        role: :writing
      )
    end
    
    def self.reader_adapter=(adapter : Granite::Adapter::Base)
      ConnectionRegistry.establish_connection(
        database: database_name,
        adapter: adapter.class,
        url: adapter.url,
        role: :reading
      )
    end
    
    # Support old-style connection macro
    macro connection(name)
      self.database_name = {{name.id.stringify}}
      
      # Look up connection from old registry and migrate to new system
      if conn = Granite::Connections[{{name.id.stringify}}]
        ConnectionRegistry.establish_connection(
          database: {{name.id.stringify}},
          adapter: conn[:writer].class,
          url: conn[:writer].url,
          role: :writing
        )
        
        if conn[:reader] != conn[:writer]
          ConnectionRegistry.establish_connection(
            database: {{name.id.stringify}},
            adapter: conn[:reader].class,
            url: conn[:reader].url,
            role: :reading
          )
        end
      else
        raise "Connection #{{{name.id.stringify}}} not found"
      end
    end
  end
  
  # Bridge the callback system
  macro included
    # Use new connection context for write operations
    before_save do
      self.class.mark_write_operation
    end
    
    before_destroy do
      self.class.mark_write_operation
    end
    
    # Remove old callbacks since new system handles this internally
    # before_save :switch_to_writer_adapter
    # before_destroy :switch_to_writer_adapter
    # after_save :update_last_write_time
    # after_save :schedule_adapter_switch
    # after_destroy :update_last_write_time
    # after_destroy :schedule_adapter_switch
  end
end