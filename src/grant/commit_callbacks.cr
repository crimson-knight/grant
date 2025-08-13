module Grant::CommitCallbacks
  macro included
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_pending_commit_callbacks = [] of Symbol
    
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_transaction_state : Symbol? = nil
  end
  
  # Queue a callback to run after commit
  private def queue_commit_callback(callback_name : Symbol)
    @_pending_commit_callbacks << callback_name
  end
  
  # Run all pending commit callbacks
  private def run_commit_callbacks
    return if @_pending_commit_callbacks.empty?
    
    callbacks = @_pending_commit_callbacks.dup
    @_pending_commit_callbacks.clear
    
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
  
  # Clear pending callbacks on rollback
  private def clear_commit_callbacks
    @_pending_commit_callbacks.clear
  end
  
  # Run rollback callbacks
  private def run_rollback_callbacks
    after_rollback if responds_to?(:after_rollback)
    clear_commit_callbacks
  end
  
  # Mark transaction state
  private def set_transaction_state(state : Symbol)
    @_transaction_state = state
  end
  
  # Check if in a transaction
  private def in_transaction?
    @_transaction_state == :in_transaction
  end
end