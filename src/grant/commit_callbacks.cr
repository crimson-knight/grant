module Grant::CommitCallbacks
  macro included
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_pending_commit_callbacks = [] of Symbol
  end

  # Queue a callback symbol for this instance (used internally after save/destroy).
  private def queue_commit_callback(callback_name : Symbol)
    @_pending_commit_callbacks << callback_name
  end

  # Called immediately after a successful save/destroy.
  #
  # If the current fiber is inside an explicit Grant::Transaction block the
  # callbacks are deferred: a closure pair (on_commit / on_rollback) is
  # registered on the innermost open transaction's state and fires when that
  # transaction's real COMMIT or ROLLBACK executes.  Savepoints share the
  # enclosing transaction's state; requires_new transactions fire their own
  # callbacks at their own commit (which is independently durable).
  #
  # If there is NO explicit transaction open (implicit single-operation
  # transaction) the callbacks are fired immediately, preserving the
  # pre-existing behaviour.
  private def run_commit_callbacks
    return if @_pending_commit_callbacks.empty?

    callbacks = @_pending_commit_callbacks.dup
    @_pending_commit_callbacks.clear

    if Grant::Transaction.in_explicit_transaction?
      # Capture the callback list by value in the closures.
      on_commit = Proc(Nil).new do
        callbacks.each do |callback_name|
          case callback_name
          when :after_commit
            after_commit if responds_to?(:after_commit)
          when :after_create_commit
            after_create_commit if responds_to?(:after_create_commit)
          when :after_update_commit
            after_update_commit if responds_to?(:after_update_commit)
          when :after_destroy_commit
            after_destroy_commit if responds_to?(:after_destroy_commit)
          end
        end
      end

      on_rollback = Proc(Nil).new do
        after_rollback if responds_to?(:after_rollback)
      end

      Grant::Transaction.enqueue_pending_callback(on_commit, on_rollback)
    else
      # No explicit transaction — fire immediately (implicit single-row tx).
      callbacks.each do |callback_name|
        case callback_name
        when :after_commit
          after_commit if responds_to?(:after_commit)
        when :after_create_commit
          after_create_commit if responds_to?(:after_create_commit)
        when :after_update_commit
          after_update_commit if responds_to?(:after_update_commit)
        when :after_destroy_commit
          after_destroy_commit if responds_to?(:after_destroy_commit)
        end
      end
    end
  end

  # Clears pending instance-level queued callbacks (used when an operation
  # fails before run_commit_callbacks is reached).
  private def clear_commit_callbacks
    @_pending_commit_callbacks.clear
  end

  # Called when an operation fails (DB::Error / Callbacks::Abort) so that the
  # implicit per-save rollback is signalled via after_rollback.  When inside
  # an explicit transaction this is a no-op: the transaction's own rollback
  # path will fire after_rollback for all pending instances at once.
  private def run_rollback_callbacks
    clear_commit_callbacks
    unless Grant::Transaction.in_explicit_transaction?
      after_rollback if responds_to?(:after_rollback)
    end
  end
end
