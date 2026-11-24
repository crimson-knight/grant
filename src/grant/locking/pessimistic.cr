require "../locking"
require "../transaction"
require "./clause"
require "./optimistic"

module Grant
  # Raised by `lock!`, `reload_with_lock` and `with_lock` on a record with
  # unsaved changes: reloading the row under lock would silently discard them.
  # Pass `force: true` to drop the changes on purpose.
  #
  # Mirrors ActiveRecord's "Locking a record with unsaved changes is not
  # supported" error.
  class UnsavedChangesLockError < ErrorBase
    def initialize(message = "Locking a record with unsaved changes is not supported; save them first or pass force: true to discard them")
      super(message)
    end
  end
end

module Grant::Locking
  alias UnsavedChangesError = Grant::UnsavedChangesLockError

  # Raised when a row lock is requested on an adapter that takes real locks
  # while no transaction is open. Outside a transaction the lock is released as
  # soon as the statement ends, so it would protect nothing.
  class TransactionRequiredError < Grant::ErrorBase
    def initialize(message = "Row locks need an open transaction; wrap the call in Model.transaction or use with_lock")
      super(message)
    end
  end
end

module Grant::Locking::Pessimistic
  macro included
    extend ClassMethods
    include ::Grant::Locking::Optimistic::Declaration
  end

  # Runs *block* in a transaction and returns its value, whatever it is (nil
  # included). *requires_new* opens a savepoint inside an open transaction;
  # *isolation* is only valid for the outermost transaction. A `Rollback` raised
  # by the block is raised again after the transaction is undone, because there
  # is no value to return.
  def self.transact(model : Grant::Base.class, requires_new : Bool, isolation : Grant::Transaction::IsolationLevel?, & : -> U) : U forall U
    result = uninitialized U
    completed = false
    model.transaction(isolation: isolation, requires_new: requires_new) do
      result = yield
      completed = true
    end
    raise Grant::Transaction::Rollback.new("with_lock block rolled back") unless completed
    result
  end

  module ClassMethods
    def lock(mode : LockMode = LockMode::Update)
      query = Query::Builder(self).new(name)
      query.lock(mode)
    end

    def lock(clause : Clause)
      query = Query::Builder(self).new(name)
      query.lock(clause)
    end

    # Loads the row with *id* under `SELECT ... FOR UPDATE` (one round trip)
    # inside a transaction and yields it. Returns the block's value, which may be
    # nil. See `#with_lock` for *requires_new* and *isolation*.
    def with_lock(id, mode : LockMode = LockMode::Update, requires_new : Bool = false, isolation : Grant::Transaction::IsolationLevel? = nil, &block : self -> U) : U forall U
      Pessimistic.transact(self, requires_new, isolation) do
        block.call(where({primary_name => id}).lock(mode).first!)
      end
    end

    # Same as `with_lock(id)`, on the first row of the table.
    def with_lock(mode : LockMode = LockMode::Update, requires_new : Bool = false, isolation : Grant::Transaction::IsolationLevel? = nil, &block : self -> U) : U forall U
      Pessimistic.transact(self, requires_new, isolation) do
        block.call(lock(mode).first!)
      end
    end
  end

  # Opens a transaction, reloads this record under a row lock and yields it.
  # Returns the block's value (nil is fine), so it works for blocks that only
  # mutate. The lock is held until the transaction ends.
  #
  # - *requires_new* opens a savepoint when a transaction is already open.
  # - *isolation* sets the isolation level of the outermost transaction.
  # - *force* discards unsaved changes instead of raising
  #   `Grant::UnsavedChangesLockError`.
  #
  # ```
  # account.with_lock do |locked|
  #   locked.update!(balance: locked.balance - 100)
  # end
  # ```
  def with_lock(mode : LockMode = LockMode::Update, requires_new : Bool = false, isolation : Grant::Transaction::IsolationLevel? = nil, force : Bool = false, & : self -> U) : U forall U
    Pessimistic.transact(self.class, requires_new, isolation) do
      reload_with_lock(mode, force: force)
      yield self
    end
  end

  # :ditto:
  def with_lock(clause : Clause, requires_new : Bool = false, isolation : Grant::Transaction::IsolationLevel? = nil, force : Bool = false, & : self -> U) : U forall U
    Pessimistic.transact(self.class, requires_new, isolation) do
      reload_with_lock(clause, force: force)
      yield self
    end
  end

  # Reloads the record with `SELECT ... FOR UPDATE` (or *mode*) and returns it.
  # Raises `Grant::UnsavedChangesLockError` when the record has unsaved changes,
  # unless *force* is true, and `Grant::Locking::TransactionRequiredError` when
  # no transaction is open on an adapter that takes row locks.
  def reload_with_lock(mode : LockMode = LockMode::Update, force : Bool = false) : self
    guard_row_lock!(mode, force)
    replace_with_locked_row(self.class.where({self.class.primary_name => primary_key_value}).lock(mode))
  end

  # :ditto:
  def reload_with_lock(clause : Clause, force : Bool = false) : self
    guard_row_lock!(LockMode::Update, force)
    replace_with_locked_row(self.class.where({self.class.primary_name => primary_key_value}).lock(clause))
  end

  # Same as `reload_with_lock`; the ActiveRecord name.
  def lock!(mode : LockMode = LockMode::Update, force : Bool = false) : self
    reload_with_lock(mode, force: force)
  end

  # :ditto:
  def lock!(clause : Clause, force : Bool = false) : self
    reload_with_lock(clause, force: force)
  end

  private def guard_row_lock!(mode : LockMode, force : Bool) : Nil
    raise Grant::UnsavedChangesLockError.new if !force && changed?
    if self.class.adapter.supports_lock_mode?(mode) && !Grant::Transaction.in_explicit_transaction?
      raise Grant::Locking::TransactionRequiredError.new
    end
  end

  # Loads the row through *locked_relation* (one SELECT) and makes this record
  # match it, with clean dirty state, exactly as `#reload` does.
  private def replace_with_locked_row(locked_relation) : self
    fresh = locked_relation.first!

    {% begin %}
      {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
        @{{column.name.id}} = fresh.@{{column.name.id}}
      {% end %}
    {% end %}

    clear_before_type_cast
    self.new_record = false
    clear_loaded_associations
    ensure_dirty_tracking_initialized
    original_attributes, changed_attributes, previous_changes = dirty_tracking_hashes
    original_attributes.clear
    changed_attributes.clear
    previous_changes.clear
    capture_original_attributes

    self
  end
end
