module Grant
  # Raised by `connected_to(shard: ...)` while `prohibit_shard_swapping` is
  # active for the current fiber.
  class ShardSwappingProhibited < Grant::ErrorBase
  end

  module ConnectionManagement
    # Snapshot of a fiber's active connection context: which database, role, and
    # shard a unit of work is targeting, and whether writes are prevented.
    #
    # Pushed and popped by `ClassMethods#connected_to`; you generally read it
    # indirectly via `current_database` / `current_role` / `current_shard` /
    # `preventing_writes?` rather than constructing one yourself.
    struct ConnectionContext
      # The target database (connection) name.
      property database : String
      # The target role (`:primary`, `:writing`, `:reading`, ...).
      property role : Symbol
      # The target shard, or `nil` for the unsharded connection.
      property shard : Symbol?
      # When true, writes raise `Grant::Transaction::ReadOnlyError`.
      property prevent_writes : Bool
      # Name of the model class whose `connected_to` created this context. The
      # context applies to that class and its subclasses; `nil` applies to every
      # model.
      property owner : String?

      def initialize(@database, @role = :primary, @shard = nil, @prevent_writes = false, @owner = nil)
      end
    end
  end

  # Per-fiber connection state: the stack of active contexts and the
  # shard-swapping flag. It lives in a slot on the fiber itself, so reading it
  # takes no lock and costs nothing for fibers that never call `connected_to`.
  #
  # :nodoc:
  class ConnectionState
    getter contexts = [] of ConnectionManagement::ConnectionContext
    property? shard_swapping_prohibited : Bool = false

    # The current fiber's state, or `nil` if it never entered a context.
    def self.current? : ConnectionState?
      Fiber.current.grant_connection_state
    end

    # The current fiber's state, created on first use.
    def self.current : ConnectionState
      fiber = Fiber.current
      fiber.grant_connection_state || (fiber.grant_connection_state = new)
    end
  end
end

class Fiber
  # Fiber-local slot for `Grant::ConnectionState`.
  # :nodoc:
  property grant_connection_state : Grant::ConnectionState?
end
