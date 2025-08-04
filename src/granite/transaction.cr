module Granite::Transaction
  class Rollback < Exception; end
  
  class SerializationError < Exception
    def initialize(message = "Transaction serialization failure")
      super(message)
    end
  end
  
  class ReadOnlyError < Exception
    def initialize(message = "Cannot modify data in read-only transaction")
      super(message)
    end
  end
  
  enum IsolationLevel
    ReadUncommitted
    ReadCommitted
    RepeatableRead
    Serializable
    
    def to_sql : String
      case self
      when ReadUncommitted then "READ UNCOMMITTED"
      when ReadCommitted then "READ COMMITTED"
      when RepeatableRead then "REPEATABLE READ"
      when Serializable then "SERIALIZABLE"
      else
        raise "Unknown isolation level: #{self}"
      end
    end
  end
  
  record Options,
    isolation : IsolationLevel? = nil,
    readonly : Bool = false,
    requires_new : Bool = false
  
  class TransactionState
    getter connection : DB::Connection
    getter options : Options
    getter savepoint_counter : Int32 = 0
    
    def initialize(@connection : DB::Connection, @options : Options)
    end
    
    def next_savepoint_name : String
      @savepoint_counter += 1
      "sp_#{@savepoint_counter}_#{Random::Secure.hex(4)}"
    end
  end
  
  @@transaction_stacks = {} of Fiber => Array(TransactionState)
  
  module ClassMethods
    private def transaction_stack : Array(TransactionState)
      stack = @@transaction_stacks[Fiber.current]?
      unless stack
        stack = [] of TransactionState
        @@transaction_stacks[Fiber.current] = stack
      end
      stack
    end
    
    private def clear_transaction_stack
      @@transaction_stacks.delete(Fiber.current)
    end
    
    def transaction(&block) : Nil
      transaction(Transaction::Options.new) { yield }
    end
    
    def transaction(options : Transaction::Options, &block) : Nil
      stack = transaction_stack
      
      if options.requires_new || stack.empty?
        execute_transaction(options, &block)
      else
        execute_savepoint(&block)
      end
    end
    
    def transaction(isolation : IsolationLevel? = nil, readonly : Bool = false, requires_new : Bool = false, &block) : Nil
      options = Transaction::Options.new(
        isolation: isolation,
        readonly: readonly,
        requires_new: requires_new
      )
      transaction(options, &block)
    end
    
    def transaction_open? : Bool
      !transaction_stack.empty?
    end
    
    def current_transaction : TransactionState?
      transaction_stack.last?
    end
    
    private def execute_transaction(options : Transaction::Options, &block)
      adapter.open do |conn|
        begin
          start_transaction(conn, options)
          state = TransactionState.new(conn, options)
          transaction_stack.push(state)
          
          yield
          
          conn.exec("COMMIT")
          transaction_stack.pop
          clear_transaction_stack if transaction_stack.empty?
        rescue ex : Rollback
          conn.exec("ROLLBACK")
          transaction_stack.pop
          clear_transaction_stack if transaction_stack.empty?
        rescue ex
          conn.exec("ROLLBACK")
          transaction_stack.pop
          clear_transaction_stack if transaction_stack.empty?
          raise ex
        end
      end
    rescue ex : DB::Error
      handle_transaction_error(ex)
    end
    
    private def execute_savepoint(&block)
      current = transaction_stack.last
      savepoint_name = current.next_savepoint_name
      
      begin
        current.connection.exec("SAVEPOINT #{savepoint_name}")
        yield
        current.connection.exec("RELEASE SAVEPOINT #{savepoint_name}")
      rescue ex : Rollback
        current.connection.exec("ROLLBACK TO SAVEPOINT #{savepoint_name}")
      rescue ex
        current.connection.exec("ROLLBACK TO SAVEPOINT #{savepoint_name}")
        raise ex
      end
    rescue ex : DB::Error
      handle_transaction_error(ex)
    end
    
    private def start_transaction(conn : DB::Connection, options : Transaction::Options)
      sql = case adapter.class
      when Granite::Adapter::Pg.class
        build_pg_transaction_sql(options)
      when Granite::Adapter::Mysql.class
        build_mysql_transaction_sql(options)
      when Granite::Adapter::Sqlite.class
        build_sqlite_transaction_sql(options)
      else
        "BEGIN"
      end
      
      conn.exec(sql)
      
      if options.isolation && adapter.class.is_a?(Granite::Adapter::Mysql.class)
        conn.exec("SET TRANSACTION ISOLATION LEVEL #{options.isolation.not_nil!.to_sql}")
      end
    end
    
    private def build_pg_transaction_sql(options : Transaction::Options) : String
      parts = ["BEGIN"]
      
      if isolation = options.isolation
        parts << "ISOLATION LEVEL #{isolation.to_sql}"
      end
      
      if options.readonly
        parts << "READ ONLY"
      else
        parts << "READ WRITE"
      end
      
      parts.join(" ")
    end
    
    private def build_mysql_transaction_sql(options : Transaction::Options) : String
      if options.readonly
        "START TRANSACTION READ ONLY"
      else
        "START TRANSACTION"
      end
    end
    
    private def build_sqlite_transaction_sql(options : Transaction::Options) : String
      isolation = options.isolation
      case isolation
      when nil
        "BEGIN"
      when .serializable?
        "BEGIN EXCLUSIVE"
      when .read_uncommitted?
        "BEGIN DEFERRED"
      else
        "BEGIN IMMEDIATE"
      end
    end
    
    private def handle_transaction_error(ex : DB::Error)
      message = ex.message || ""
      
      case message
      when /deadlock/i
        raise Granite::Locking::DeadlockError.new(message)
      when /serialization failure/i, /could not serialize/i
        raise Transaction::SerializationError.new(message)
      when /read-only transaction/i
        raise Transaction::ReadOnlyError.new(message)
      else
        raise ex
      end
    end
  end
  
  def transaction(&block)
    self.class.transaction { yield }
  end
  
  def transaction(options : Transaction::Options, &block)
    self.class.transaction(options) { yield }
  end
end