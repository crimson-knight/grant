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
  # Main logger for Granite
  Log = ::Log.for("granite")
  
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
      backend = Log::IOBackend.new(formatter: SQLFormatter.new)
      Log.builder.bind "granite.sql", :debug, backend
    end
    
    # Set up model logging for development
    def self.setup_model_logging
      backend = Log::IOBackend.new(formatter: ModelFormatter.new)
      Log.builder.bind "granite.model", :debug, backend
    end
    
    # Set up association logging for development
    def self.setup_association_logging
      backend = Log::IOBackend.new(formatter: AssociationFormatter.new)
      Log.builder.bind "granite.association", :debug, backend
    end
    
    # Set up transaction logging for development
    def self.setup_transaction_logging
      backend = Log::IOBackend.new(formatter: TransactionFormatter.new)
      Log.builder.bind "granite.transaction", :debug, backend
    end
    
    # Set up query builder logging for development
    def self.setup_query_logging
      backend = Log::IOBackend.new(formatter: QueryFormatter.new)
      Log.builder.bind "granite.query", :debug, backend
    end
    
    # Custom formatter for SQL queries
    class SQLFormatter < Log::StaticFormatter
      def format(entry : Log::Entry, io : IO)
        # Extract data
        model = entry.data[:model]?
        duration_ms = entry.data[:duration_ms]?
        sql = entry.data[:sql]?
        row_count = entry.data[:row_count]?
        rows_affected = entry.data[:rows_affected]?
        
        # Format header with timing
        io << "  "
        
        # Severity indicator
        case entry.severity
        when .warn?
          io << "⚠ ".colorize(:yellow)
        when .error?
          io << "✗ ".colorize(:red)
        else
          io << "▸ ".colorize(:dark_gray)
        end
        
        # Model name
        if model
          io << model.to_s.colorize(:cyan)
          io << " "
        end
        
        # Timing
        io << "("
        if duration_ms
          duration = duration_ms.as(Float64)
          color = case duration
          when .>(100) then :red
          when .>(50)  then :yellow
          else              :green
          end
          io << duration.round(2).to_s.colorize(color).bold
          io << "ms"
        else
          io << "?ms"
        end
        io << ")"
        
        # Row count or rows affected
        if row_count
          io << " → #{row_count} rows".colorize(:dark_gray)
        elsif rows_affected
          io << " → #{rows_affected} affected".colorize(:dark_gray)
        end
        
        io << "\n"
        
        # Format SQL
        if sql
          io << "    "
          io << format_sql(sql.to_s)
          io << "\n"
        else
          io << "    "
          io << entry.message.colorize(:light_gray)
          io << "\n"
        end
        
        # Show error if present
        if error = entry.data[:error]?
          io << "    "
          io << "ERROR: ".colorize(:red)
          io << error.to_s.colorize(:light_red)
          io << "\n"
        end
      end
      
      private def format_sql(sql : String) : String
        # SQL keywords
        keywords = %w[SELECT INSERT UPDATE DELETE FROM WHERE JOIN LEFT RIGHT INNER OUTER ON 
                      ORDER BY GROUP BY HAVING LIMIT OFFSET AND OR NOT IN EXISTS BETWEEN 
                      LIKE IS NULL AS DISTINCT COUNT SUM AVG MIN MAX SET VALUES INTO
                      CREATE DROP ALTER TABLE INDEX PRIMARY KEY FOREIGN REFERENCES]
        
        formatted = sql.dup
        
        # Highlight keywords
        keywords.each do |keyword|
          formatted = formatted.gsub(/\b#{keyword}\b/i) { |match| match.colorize(:blue).bold.to_s }
        end
        
        # Highlight strings
        formatted = formatted.gsub(/'[^']*'/) { |match| match.colorize(:yellow).to_s }
        
        # Highlight numbers
        formatted = formatted.gsub(/\b\d+(\.\d+)?\b/) { |match| match.colorize(:magenta).to_s }
        
        # Highlight table/column names in quotes
        formatted = formatted.gsub(/"[^"]+"|`[^`]+`/) { |match| match.colorize(:cyan).to_s }
        
        # Highlight placeholders
        formatted = formatted.gsub(/\$\d+|\?/) { |match| match.colorize(:light_gray).underline.to_s }
        
        formatted
      end
    end
    
    # Custom formatter for model operations
    class ModelFormatter < Log::StaticFormatter
      def format(entry : Log::Entry, io : IO)
        model = entry.data[:model]?
        id = entry.data[:id]?
        attributes = entry.data[:attributes]?
        error = entry.data[:error]?
        new_record = entry.data[:new_record]?
        
        io << "  "
        
        # Operation indicator
        case entry.message
        when /Creating/i
          io << "➕ ".colorize(:green)
        when /Created/i
          io << "✓ ".colorize(:green)
        when /Updating/i
          io << "✏ ".colorize(:yellow)
        when /Updated/i
          io << "✓ ".colorize(:yellow)
        when /Destroying/i, /Deleting/i
          io << "🗑 ".colorize(:red)
        when /Destroyed/i, /Deleted/i
          io << "✓ ".colorize(:red)
        when /Failed/i
          io << "✗ ".colorize(:red).bold
        else
          io << "• ".colorize(:blue)
        end
        
        # Model and ID
        if model
          io << model.to_s.colorize(:cyan).bold
        end
        
        if id
          io << "#".colorize(:dark_gray)
          io << id.to_s.colorize(:magenta)
        elsif new_record
          io << " (new)".colorize(:dark_gray)
        end
        
        io << " - "
        io << entry.message
        io << "\n"
        
        # Show attributes if present
        if attributes && entry.severity.debug?
          io << "    Attributes: ".colorize(:dark_gray)
          io << attributes.to_s.colorize(:light_gray)
          io << "\n"
        end
        
        # Show error if present
        if error
          io << "    Error: ".colorize(:red)
          io << error.to_s.colorize(:light_red)
          io << "\n"
        end
      end
    end
    
    # Custom formatter for associations
    class AssociationFormatter < Log::StaticFormatter
      def format(entry : Log::Entry, io : IO)
        model = entry.data[:model]?
        association = entry.data[:association]?
        target_class = entry.data[:target_class]?
        duration_ms = entry.data[:duration_ms]?
        records_loaded = entry.data[:records_loaded]?
        
        io << "  "
        io << "↔ ".colorize(:magenta)
        
        # Source model
        if model
          io << model.to_s.colorize(:cyan)
        end
        
        # Association name
        if association
          io << "#".colorize(:dark_gray)
          io << association.to_s.colorize(:magenta).bold
        end
        
        # Target class
        if target_class
          io << " → ".colorize(:dark_gray)
          io << target_class.to_s.colorize(:cyan)
        end
        
        # Timing
        if duration_ms
          duration = duration_ms.as(Float64)
          io << " ("
          io << duration.round(2).to_s.colorize(duration > 50 ? :yellow : :green)
          io << "ms)"
        end
        
        # Record count
        if records_loaded
          io << " [#{records_loaded} records]".colorize(:dark_gray)
        end
        
        io << "\n"
      end
    end
    
    # Custom formatter for transactions
    class TransactionFormatter < Log::StaticFormatter
      def format(entry : Log::Entry, io : IO)
        io << "  "
        
        case entry.message
        when /BEGIN/i
          io << "▶ ".colorize(:green)
        when /COMMIT/i
          io << "✓ ".colorize(:green)
        when /ROLLBACK/i
          io << "⟲ ".colorize(:red)
        else
          io << "• ".colorize(:blue)
        end
        
        io << "Transaction: ".colorize(:cyan)
        io << entry.message
        io << "\n"
      end
    end
    
    # Custom formatter for query builder operations
    class QueryFormatter < Log::StaticFormatter
      def format(entry : Log::Entry, io : IO)
        model = entry.data[:model]?
        operation = entry.data[:operation]?
        
        io << "  "
        io << "? ".colorize(:blue)
        
        if model
          io << model.to_s.colorize(:cyan)
          io << " "
        end
        
        if operation
          io << operation.to_s.colorize(:magenta)
          io << ": "
        end
        
        io << entry.message.colorize(:light_gray)
        io << "\n"
      end
    end
  end
end