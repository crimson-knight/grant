module Grant
  class Connection
    # Runs *block* in a transaction on this connection's write role and returns
    # the block's value (`nil` if it raised `Grant::Transaction::Rollback`).
    # Shares the fiber-local transaction stack with `Model.transaction`, so
    # model saves inside the block join it when they use the same database.
    #
    # ```
    # Grant.connection.transaction do
    #   Grant.connection.execute("UPDATE accounts SET balance = balance - 100 WHERE id = 1")
    #   Grant.connection.execute("UPDATE accounts SET balance = balance + 100 WHERE id = 2")
    # end
    # ```
    def transaction(options : Grant::Transaction::Options, & : -> T) : T? forall T
      Grant::Transaction.run(adapter(:writing), options) { yield }
    end

    # Keyword form of `#transaction`; accepts the same options as `Model.transaction`.
    def transaction(isolation : Grant::Transaction::IsolationLevel? = nil, readonly : Bool = false, requires_new : Bool = false, joinable : Bool = true, independent : Bool = false, & : -> T) : T? forall T
      options = Grant::Transaction::Options.new(
        isolation: isolation,
        readonly: readonly,
        requires_new: requires_new,
        joinable: joinable,
        independent: independent
      )
      transaction(options) { yield }
    end

    # Opens a transaction that stays open until `Handle#commit` or
    # `Handle#rollback` (or `#commit` / `#rollback` on this connection). When a
    # transaction is already open on the database, opens a savepoint and returns
    # a nested handle. A real manual transaction holds one pooled connection
    # until it is settled; always settle it.
    #
    # ```
    # connection = Grant.connection
    # handle = connection.begin_transaction
    # connection.execute("INSERT INTO logs (message) VALUES ('hi')")
    # handle.commit
    # ```
    def begin_transaction(isolation : Grant::Transaction::IsolationLevel? = nil, readonly : Bool = false) : Grant::Transaction::Handle
      options = Grant::Transaction::Options.new(isolation: isolation, readonly: readonly)
      Grant::Transaction.begin_manual(adapter(:writing), options)
    end

    # Commits the innermost manually opened transaction (or savepoint).
    # Raises `Grant::Transaction::NotOpenError` when there is none.
    def commit : Nil
      innermost_manual_handle.commit
    end

    # Rolls back the innermost manually opened transaction (or savepoint).
    def rollback : Nil
      innermost_manual_handle.rollback
    end

    # Runs *block* inside a savepoint of the open transaction. *name* must be a
    # plain SQL identifier; it defaults to a per-transaction counter name. A
    # `Rollback` (or exception) rolls back to the savepoint only.
    def savepoint(name : String? = nil, & : -> T) : T? forall T
      Grant::Transaction.with_savepoint(adapter(:writing), name) { yield }
    end

    private def innermost_manual_handle : Grant::Transaction::Handle
      state = Grant::Transaction.current_state_for?(adapter(:writing))
      raise Grant::Transaction::NotOpenError.new unless state
      if nested = state.manual_savepoints.last?
        return nested
      end
      raise Grant::Transaction::NotOpenError.new("The open transaction was not started with begin_transaction") unless state.manual?
      state.handle
    end
  end

  # Runs *block* in a transaction on *database* (the default database when
  # omitted) without borrowing a model class, and returns the block's value.
  # Options are those of `Model.transaction`.
  #
  # ```
  # Grant.transaction do
  #   Grant.connection.execute("DELETE FROM sessions")
  # end
  # Grant.transaction("analytics", isolation: :serializable) { ... }
  # ```
  def self.transaction(database : String? = nil, isolation : Grant::Transaction::IsolationLevel? = nil, readonly : Bool = false, requires_new : Bool = false, joinable : Bool = true, independent : Bool = false, & : -> T) : T? forall T
    Grant.connection(database).transaction(
      isolation: isolation,
      readonly: readonly,
      requires_new: requires_new,
      joinable: joinable,
      independent: independent
    ) { yield }
  end

  # Runs *block* after the outermost open transaction on this fiber commits, or
  # immediately when none is open. Dropped when the transaction rolls back.
  def self.after_all_transactions_commit(&block : -> Nil) : Nil
    Grant::Transaction.after_all_transactions_commit(&block)
  end
end
