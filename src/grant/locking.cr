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

    # Renders the adapter-specific SQL clause for this lock mode.
    #
    # Delegates to the adapter via virtual dispatch (`#lock_clause`) rather
    # than `case`ing over concrete adapter class literals. The old approach
    # referenced `Grant::Adapter::Pg`/`Mysql`/`Sqlite` directly, which forced
    # Crystal to resolve — and therefore compile — all three adapter shards
    # even for an app that only requires one (issue #40). Each adapter now
    # owns its lock SQL; only the adapter that was actually required
    # contributes a `#lock_clause` override.
    def to_sql(adapter : Grant::Adapter::Base) : String
      adapter.lock_clause(self)
    end
  end
end
