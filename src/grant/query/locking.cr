require "./builder"
require "../locking/clause"

class Grant::Query::Builder(Model)
  # The vendor lock clause set through `lock(clause)`, or nil. A relation holds
  # either this or a `lock_mode`, never both.
  # Locks the selected rows with a vendor clause the `LockMode` enum has no
  # name for (`FOR NO KEY UPDATE`, `FOR UPDATE OF users`). Returns `self`.
  # Build the *clause* with `Grant::Locking.clause`, which accepts only
  # literals and constants. SQLite has no row locks, so the clause is dropped
  # there.
  def lock!(clause : Grant::Locking::Clause) : self
    reset_load_state
    @relation_state.lock_mode = nil
    @relation_state.lock_clause = clause
    self
  end

  # `lock(true)` is `lock`; `lock(false)` clears any lock, including one
  # inherited from a scope.
  def lock!(enabled : Bool) : self
    enabled ? lock! : unlock!
  end

  # Drops any row lock the relation carries. Returns `self`.
  def unlock! : self
    reset_load_state
    @relation_state.lock_mode = nil
    @relation_state.lock_clause = nil
    self
  end

  def lock(clause : Grant::Locking::Clause) : self
    chain_copy.lock!(clause)
  end

  def lock(enabled : Bool) : self
    chain_copy.lock!(enabled)
  end

  def unlock : self
    chain_copy.unlock!
  end

  # True when the relation carries a row lock of either kind.
  def locked? : Bool
    !@relation_state.lock_mode.nil? || !@relation_state.lock_clause.nil?
  end

  # The lock SQL for *adapter*: the mode's clause, or the custom clause. Adapters
  # without row locks (SQLite) render nothing for either.
  #
  # :nodoc:
  def lock_sql(adapter : Grant::Adapter::Base) : String?
    if mode = @relation_state.lock_mode
      mode.to_sql(adapter)
    elsif clause = @relation_state.lock_clause
      adapter.supports_lock_mode?(Grant::Locking::LockMode::Update) ? clause.sql : ""
    end
  end

  # Takes *other*'s lock, if it has one, in place of this relation's.
  #
  # :nodoc:
  def take_lock_from!(other : Grant::Query::Builder(Model)) : Nil
    if mode = other.lock_mode
      @relation_state.lock_clause = nil
      @relation_state.lock_mode = mode
    elsif clause = other.lock_clause
      @relation_state.lock_mode = nil
      @relation_state.lock_clause = clause
    end
  end
end
