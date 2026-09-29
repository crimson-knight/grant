module Grant
  # Publish/subscribe for Grant's instrumentation events.
  #
  # ```
  # subscription = Grant::Notifications.subscribe(Grant::Events::SQL) do |event|
  #   Metrics.timing("db.query", event.duration, tags: {model: event.name})
  # end
  # subscription.unsubscribe
  # ```
  #
  # Publishing is synchronous, on the fiber that ran the statement. With no
  # subscriber for an event type nothing is built: `instrument` only calls its
  # block after one array-size check. Keep handlers fast, and hand slow work to
  # another fiber.
  module Notifications
    # Handle returned by `subscribe`.
    class Subscription(T)
      getter handler : Proc(T, Nil)

      def initialize(@handler : Proc(T, Nil))
      end

      def unsubscribe : Nil
        T.remove_subscription(self)
      end
    end

    # Included by every event struct. Gives each event type its own subscriber
    # list. The array is replaced, never mutated, so publishers iterate a
    # snapshot without a lock.
    module Publishable
      macro included
        @@subscriptions = [] of Grant::Notifications::Subscription({{@type}})
        @@subscription_mutex = Mutex.new

        # :nodoc:
        def self.subscribed? : Bool
          !@@subscriptions.empty?
        end

        # :nodoc:
        def self.add_subscription(subscription : Grant::Notifications::Subscription({{@type}})) : Nil
          @@subscription_mutex.synchronize { @@subscriptions = @@subscriptions + [subscription] }
        end

        # :nodoc:
        def self.remove_subscription(subscription : Grant::Notifications::Subscription({{@type}})) : Nil
          @@subscription_mutex.synchronize { @@subscriptions = @@subscriptions.reject(&.same?(subscription)) }
        end

        # :nodoc:
        def self.publish(event : self) : Nil
          @@subscriptions.each do |subscription|
            begin
              subscription.handler.call(event)
            rescue ex
              # An instrumentation handler must never fail the statement it observes.
              Grant::Log.error(exception: ex) { "{{@type}} subscriber raised" }
            end
          end
        end
      end
    end

    # Registers *handler* for events of type *event_type*.
    def self.subscribe(event_type : T.class, &handler : T -> Nil) : Subscription(T) forall T
      subscription = Subscription(T).new(handler)
      event_type.add_subscription(subscription)
      subscription
    end

    # Registers *handler* for the duration of the block, then removes it.
    def self.subscribed(event_type : T.class, handler : T -> Nil, & : -> R) : R forall T, R
      subscription = subscribe(event_type, &handler)
      begin
        yield
      ensure
        subscription.unsubscribe
      end
    end

    # Whether any handler listens for *event_type*.
    def self.subscribed?(event_type : T.class) : Bool forall T
      event_type.subscribed?
    end

    # Builds the event with *block* and publishes it, only when a handler is
    # registered. The block is inlined, so nothing is allocated otherwise.
    def self.instrument(event_type : T.class, & : -> T) : Nil forall T
      return unless event_type.subscribed?
      event_type.publish(yield)
    end

    # Runs *block* marked as an async query fiber whose statements belong to
    # *origin*, so SQL events report `async?` and spec helpers can attribute
    # them to the fiber that started the work.
    def self.async_from(origin : Fiber, & : -> R) : R forall R
      fiber = Fiber.current
      fiber.grant_async_origin = origin
      begin
        yield
      ensure
        fiber.grant_async_origin = nil
      end
    end

    # Publishes a `Events::SQL` for a statement that took *duration*. Called by
    # the adapter around every statement that reports its SQL.
    def self.publish_sql(adapter : Grant::Adapter::Base, sql : String, binds, duration : Time::Span, name : String? = nil) : Nil
      instrument(Events::SQL) do
        Events::SQL.new(
          sql,
          columns_binds(binds),
          name || "SQL",
          duration,
          adapter.name,
          false,
          !Fiber.current.grant_async_origin.nil?
        )
      end
    end

    private def self.columns_binds(binds) : Array(Grant::Columns::Type)
      result = [] of Grant::Columns::Type
      binds.try &.each do |value|
        result << value if value.is_a?(Grant::Columns::Type)
      end
      result
    end
  end

  # Typed payloads published through `Grant::Notifications`. Every event is an
  # immutable struct, so a subscriber reads named fields instead of a hash.
  module Events
    # A SQL statement sent to the database.
    #
    # - *sql*: the statement as sent, with the adapter's placeholders.
    # - *binds*: the bound values, in placeholder order.
    # - *name*: the model that issued the statement, or `"SQL"` when none did.
    # - *duration*: wall time from checkout to the end of the block that ran
    #   the statement, including reading its rows.
    # - *connection*: name of the adapter that ran it.
    # - *cached*: `true` when a query cache answered without the database.
    # - *async*: `true` when the statement ran on an `Async::Result` fiber.
    struct SQL
      include Grant::Notifications::Publishable

      getter sql : String
      getter binds : Array(Grant::Columns::Type)
      getter name : String
      getter duration : Time::Span
      getter connection : String
      getter? cached : Bool
      getter? async : Bool

      def initialize(@sql, @binds, @name, @duration, @connection, @cached = false, @async = false)
      end
    end

    # How a real transaction ended.
    enum TransactionOutcome
      Commit
      Rollback
    end

    # A transaction was opened (`BEGIN`), or a savepoint inside one
    # (`SAVEPOINT`). *options* are those of the enclosing real transaction;
    # *savepoint_name* is `nil` for a real transaction.
    struct TransactionStart
      include Grant::Notifications::Publishable

      getter connection : String
      getter options : Grant::Transaction::Options
      getter savepoint_name : String?

      def initialize(@connection, @options, @savepoint_name = nil)
      end

      # Whether this opened a savepoint rather than a real transaction.
      def savepoint? : Bool
        !@savepoint_name.nil?
      end
    end

    # A transaction or savepoint ended. *duration* runs from `BEGIN` (or
    # `SAVEPOINT`) to the end of the `COMMIT`, `ROLLBACK`, `RELEASE SAVEPOINT`
    # or `ROLLBACK TO SAVEPOINT`, so it is the figure to alert on for slow
    # transactions. A released savepoint reports `Commit`, although only the
    # enclosing transaction's commit makes its work durable.
    struct Transaction
      include Grant::Notifications::Publishable

      getter connection : String
      getter outcome : TransactionOutcome
      getter duration : Time::Span
      getter options : Grant::Transaction::Options
      getter savepoint_name : String?

      def initialize(@connection, @outcome, @duration, @options, @savepoint_name = nil)
      end

      # Whether this closed a savepoint rather than a real transaction.
      def savepoint? : Bool
        !@savepoint_name.nil?
      end

      def committed? : Bool
        @outcome.commit?
      end

      def rolled_back? : Bool
        @outcome.rollback?
      end
    end

    # A record was built from a database row.
    struct Instantiation
      include Grant::Notifications::Publishable

      getter class_name : String
      getter record_count : Int32

      def initialize(@class_name, @record_count = 1)
      end
    end

    # An association that was not preloaded was read on a strict-loading
    # record. Published whether Grant then raises or only logs.
    struct StrictLoadingViolation
      include Grant::Notifications::Publishable

      getter owner : String
      getter association : String

      def initialize(@owner, @association)
      end
    end
  end
end

class Fiber
  # Fiber that started the async work this fiber runs, if any.
  # :nodoc:
  property grant_async_origin : Fiber?
end
