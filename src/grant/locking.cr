module Grant::Locking
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
    
    def to_sql(adapter : Grant::Adapter::Base) : String
      case adapter
      when Grant::Adapter::Pg
        postgres_sql
      when Grant::Adapter::Mysql
        mysql_sql
      when Grant::Adapter::Sqlite
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