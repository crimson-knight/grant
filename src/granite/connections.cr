module Granite
  # Legacy connections module - now delegates to ConnectionRegistry
  # This will be removed in a future version
  class Connections
    class_property connection_switch_wait_period : Int32 = 2000
    
    # For backward compatibility - delegates to ConnectionRegistry
    def self.<<(adapter : Granite::Adapter::Base) : Nil
      ConnectionRegistry.establish_connection(
        database: adapter.name,
        adapter: adapter.class,
        url: adapter.url
      )
    end

    def self.<<(data : NamedTuple(name: String, reader: String, writer: String, adapter_type: Granite::Adapter::Base.class)) : Nil
      # Register writer
      ConnectionRegistry.establish_connection(
        database: data[:name],
        adapter: data[:adapter_type],
        url: data[:writer],
        role: :writing
      )
      
      # Register reader if different
      if data[:reader] != data[:writer]
        ConnectionRegistry.establish_connection(
          database: data[:name],
          adapter: data[:adapter_type],
          url: data[:reader],
          role: :reading
        )
      end
    end

    # Returns a registered connection with the given *name*, otherwise `nil`.
    def self.[](name : String) : {writer: Granite::Adapter::Base, reader: Granite::Adapter::Base}?
      writer = ConnectionRegistry.get_adapter(name, :writing) rescue nil
      reader = ConnectionRegistry.get_adapter(name, :reading) rescue writer
      
      return nil unless writer
      {writer: writer, reader: reader || writer}
    end
    
    # For test compatibility - returns adapters from ConnectionRegistry
    def self.registered_connections
      result = [] of {writer: Granite::Adapter::Base, reader: Granite::Adapter::Base}
      
      # Get all unique database names from ConnectionRegistry
      databases = ConnectionRegistry.databases
      
      databases.each do |db|
        writer = ConnectionRegistry.get_adapter(db, :writing) rescue ConnectionRegistry.get_adapter(db, :primary) rescue nil
        reader = ConnectionRegistry.get_adapter(db, :reading) rescue writer
        
        if writer
          result << {writer: writer, reader: reader || writer}
        end
      end
      
      result
    end
  end
end
