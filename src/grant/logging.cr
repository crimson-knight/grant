# Crystal-native logging for Grant ORM
#
# Provides structured logging for all Grant operations using Crystal's Log module.
# This enables debugging, monitoring, and performance analysis without the overhead
# of a pub-sub system.
#
# ## Usage
#
# ```crystal
# # Configure logging in your application
# Log.setup do |c|
#   backend = Log::IOBackend.new(formatter: Log::ShortFormat)
#   c.bind "grant.sql", :debug, backend
#   c.bind "grant.model", :info, backend
# end
#
# # SQL queries will be logged automatically
# User.where(active: true).select
# # => [grant.sql] Query executed (1.23ms) - SELECT * FROM users WHERE active = true
# ```

module Grant
  # Main logger for Grant is defined in grant.cr
  
  # Sub-loggers for different components
  module Logs
    # SQL query logging
    SQL = ::Log.for("grant.sql")
    
    # Model lifecycle events (create, update, destroy)
    Model = ::Log.for("grant.model")
    
    # Transaction operations
    Transaction = ::Log.for("grant.transaction")
    
    # Association loading
    Association = ::Log.for("grant.association")
    
    # Query builder operations
    Query = ::Log.for("grant.query")
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
      backend = ::Log::IOBackend.new(STDOUT)
      ::Log.setup do |c|
        c.bind "grant.sql", :debug, backend
      end
    end
    
    # Set up model logging for development
    def self.setup_model_logging
      backend = ::Log::IOBackend.new(STDOUT)
      ::Log.setup do |c|
        c.bind "grant.model", :debug, backend
      end
    end
    
    # Set up association logging for development
    def self.setup_association_logging
      backend = ::Log::IOBackend.new(STDOUT)
      ::Log.setup do |c|
        c.bind "grant.association", :debug, backend
      end
    end
    
    # Set up transaction logging for development
    def self.setup_transaction_logging
      backend = ::Log::IOBackend.new(STDOUT)
      ::Log.setup do |c|
        c.bind "grant.transaction", :debug, backend
      end
    end
    
    # Set up query builder logging for development
    def self.setup_query_logging
      backend = ::Log::IOBackend.new(STDOUT)
      ::Log.setup do |c|
        c.bind "grant.query", :debug, backend
      end
    end
    
    # Note: Custom formatters removed due to Crystal Log API changes
    # Logging now uses standard formatters
  end
end