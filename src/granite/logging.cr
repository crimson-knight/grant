# Crystal-native logging for Granite ORM
#
# Provides structured logging for all Granite operations using Crystal's Log module.
# This enables debugging, monitoring, and performance analysis without the overhead
# of a pub-sub system.
#
# ## Usage
#
# ```crystal
# # Configure logging in your application
# Log.setup do |c|
#   backend = Log::IOBackend.new(formatter: Log::ShortFormat)
#   c.bind "granite.sql", :debug, backend
#   c.bind "granite.model", :info, backend
# end
#
# # SQL queries will be logged automatically
# User.where(active: true).select
# # => [granite.sql] Query executed (1.23ms) - SELECT * FROM users WHERE active = true
# ```

module Granite
  # Main logger for Granite is defined in granite.cr
  
  # Sub-loggers for different components
  module Logs
    # SQL query logging
    SQL = ::Log.for("granite.sql")
    
    # Model lifecycle events (create, update, destroy)
    Model = ::Log.for("granite.model")
    
    # Transaction operations
    Transaction = ::Log.for("granite.transaction")
    
    # Association loading
    Association = ::Log.for("granite.association")
    
    # Query builder operations
    Query = ::Log.for("granite.query")
  end
  
  # Development helpers for pretty logging
  module Development
    # Set up all development logging with pretty formatters
    def self.setup_logging
      setup_sql_logging
      setup_model_logging
      setup_association_logging
      setup_transaction_logging
      setup_query_logging
    end
    
    # Set up pretty SQL logging for development
    def self.setup_sql_logging
      backend = Log::IOBackend.new
      Log.builder.bind "granite.sql", :debug, backend
    end
    
    # Set up model logging for development
    def self.setup_model_logging
      backend = Log::IOBackend.new
      Log.builder.bind "granite.model", :debug, backend
    end
    
    # Set up association logging for development
    def self.setup_association_logging
      backend = Log::IOBackend.new
      Log.builder.bind "granite.association", :debug, backend
    end
    
    # Set up transaction logging for development
    def self.setup_transaction_logging
      backend = Log::IOBackend.new
      Log.builder.bind "granite.transaction", :debug, backend
    end
    
    # Set up query builder logging for development
    def self.setup_query_logging
      backend = Log::IOBackend.new
      Log.builder.bind "granite.query", :debug, backend
    end
    
    # Note: Custom formatters removed due to Crystal Log API changes
    # Logging now uses standard formatters
  end
end