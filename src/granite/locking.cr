module Granite::Locking
  class LockWaitTimeoutError < Exception
    def initialize(message = "Lock wait timeout exceeded")
      super(message)
    end
  end
  
  class LockNotAvailableError < Exception
    def initialize(message = "Could not obtain lock")
      super(message)
    end
  end
  
  class DeadlockError < Exception
    def initialize(message = "Deadlock detected")
      super(message)
    end
  end
  
  enum LockMode
    Update
    Share
    UpdateNoWait
    UpdateSkipLocked
    ShareNoWait
    ShareSkipLocked
    
    def to_sql(adapter : Granite::Adapter::Base) : String
      case adapter
      when Granite::Adapter::Pg
        postgres_sql
      when Granite::Adapter::Mysql
        mysql_sql
      when Granite::Adapter::Sqlite
        sqlite_sql
      else
        raise "Unsupported adapter for locking: #{adapter.class}"
      end
    end
    
    private def postgres_sql : String
      case self
      when Update then "FOR UPDATE"
      when Share then "FOR SHARE"
      when UpdateNoWait then "FOR UPDATE NOWAIT"
      when UpdateSkipLocked then "FOR UPDATE SKIP LOCKED"
      when ShareNoWait then "FOR SHARE NOWAIT"
      when ShareSkipLocked then "FOR SHARE SKIP LOCKED"
      else
        self.to_s
      end
    end
    
    private def mysql_sql : String
      case self
      when Update then "FOR UPDATE"
      when Share then "LOCK IN SHARE MODE"
      when UpdateNoWait then "FOR UPDATE NOWAIT"
      when UpdateSkipLocked then "FOR UPDATE SKIP LOCKED"
      else
        raise LockNotAvailableError.new("Lock mode #{self} not supported in MySQL")
      end
    end
    
    private def sqlite_sql : String
      ""
    end
  end
end