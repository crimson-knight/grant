require "log/spec"

# Records the SQL Grant logs while a block runs, so association specs can
# assert how many queries loading N owners costs.
module AssociationQueryCounter
  # The SQL statements logged while the block runs, in order.
  def self.statements(&) : Array(String)
    backend = Log::MemoryBackend.new
    Log.builder.bind("grant.sql", Log::Severity::Debug, backend)
    begin
      yield
    ensure
      Log.builder.unbind("grant.sql", Log::Severity::Debug, backend)
    end
    # Grant logs each statement three times (SQL, binds, result); keep the result line.
    backend.entries.map(&.message).select(&.starts_with?("Query executed"))
  end

  # How many SELECT statements ran while the block did.
  def self.selects(&) : Int32
    statements { yield }.count(&.includes?("SELECT"))
  end
end
