# Captures the transaction-control statements Grant issues (BEGIN, SAVEPOINT,
# COMMIT, ...) through the `grant.transaction` debug log.
module TransactionSqlRecorder
  def self.record(& : ->) : Array(String)
    backend = ::Log::MemoryBackend.new
    ::Log.builder.bind("grant.transaction", ::Log::Severity::Debug, backend)
    begin
      yield
    ensure
      ::Log.builder.bind("grant.transaction", ::Log::Severity::None, ::Log::MemoryBackend.new)
    end
    backend.entries.map(&.message)
  end

  # Statements that open a transaction on any adapter.
  BEGIN_PATTERN = /\A(BEGIN|START TRANSACTION)/

  def self.begins(statements : Array(String)) : Array(String)
    statements.select { |statement| statement =~ BEGIN_PATTERN }
  end
end
