require "spec"
require "../../grant"

module Grant::Spec
  # Wraps every example in a transaction on each registered connection and rolls
  # it back afterwards, so examples never leave rows behind and the suite needs
  # no `DELETE` between them. Call it once, from `spec_helper.cr`:
  #
  # ```
  # Grant::Spec.transactional
  # ```
  #
  # The wrapper is opened with `joinable: false`: a `transaction` block in the
  # code under test becomes a savepoint, so its `Rollback` and errors undo only
  # its own work, as they would in production. A connection only sees its own
  # uncommitted rows, so models on different registered connections do not see
  # each other's writes, and a statement run from another fiber (outside an
  # `Async::Result`) uses a pool connection that cannot see the wrapper's rows.
  #
  # *only* limits the wrapper to the named connections.
  def self.transactional(only : Array(String)? = nil) : Nil
    ::Spec.around_each do |example|
      within_transaction(only) { example.run }
    end
  end

  # Runs *block* inside the wrapper transactions and rolls them back, returning
  # the block's value. Use it where `transactional` cannot apply, for example
  # around a single example or a `before_all`.
  def self.within_transaction(only : Array(String)? = nil, & : -> T) : T forall T
    handles = begin_test_transactions(only)
    begin
      yield
    ensure
      rollback_test_transactions(handles)
    end
  end

  private def self.begin_test_transactions(only : Array(String)?) : Array(Grant::Transaction::Handle)
    options = Grant::Transaction::Options.new(joinable: false)
    handles = [] of Grant::Transaction::Handle
    begin
      test_adapters(only).each { |adapter| handles << Grant::Transaction.begin_manual(adapter, options) }
    rescue ex
      rollback_test_transactions(handles) rescue nil
      raise ex
    end
    handles
  end

  # Rolls every handle back, newest first, and raises the first failure only
  # after all of them were attempted so one bad connection cannot leak the rest.
  private def self.rollback_test_transactions(handles : Array(Grant::Transaction::Handle)) : Nil
    failure = nil.as(::Exception?)
    handles.reverse_each do |handle|
      next unless handle.open?
      begin
        handle.rollback
      rescue ex
        failure ||= ex
      end
    end
    if error = failure
      raise error
    end
  end

  private def self.test_adapters(only : Array(String)?) : Array(Grant::Adapter::Base)
    adapters = [] of Grant::Adapter::Base
    Grant::Connections.registered_connections.each do |pair|
      writer = pair[:writer]
      next if only && !only.includes?(writer.name)
      adapters << writer unless adapters.any?(&.same?(writer))
    end
    adapters
  end
end
