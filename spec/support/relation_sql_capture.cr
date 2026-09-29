# Captures the SQL statements Grant logs at debug level while a block runs, so
# relation specs can assert how many queries an operation issued and what they
# looked like. The backend is (re)bound and cleared on every capture, because the
# spec runner resets logging between examples.
module RelationSqlCapture
  BACKEND = Log::MemoryBackend.new

  # SQL statements Grant reports as executed while the block runs, in order.
  # The prepared-statement and bind-value log lines are filtered out.
  def self.statements(& : ->) : Array(String)
    Log.builder.bind("grant.sql", ::Log::Severity::Debug, BACKEND)
    BACKEND.entries.clear
    yield
    BACKEND.entries.compact_map do |entry|
      message = entry.message
      next unless message.starts_with?("Query executed (")
      message.sub(/\AQuery executed \([^)]*\) - /, "").sub(/ \[[\w:]+\] \[rows: \d+\]\z/, "")
    end
  end
end

def capture_sql(& : ->) : Array(String)
  RelationSqlCapture.statements { yield }
end
