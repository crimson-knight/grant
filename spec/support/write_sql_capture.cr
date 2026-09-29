# Captures the write statements (INSERT / UPDATE / DELETE) Grant sends while a
# block runs, so persistence specs can assert how many statements an operation
# issued and which columns they touched. ANSI color codes are stripped.
module WriteSqlCapture
  BACKEND = Log::MemoryBackend.new

  def self.statements(& : ->) : Array(String)
    Log.builder.bind("grant.sql", ::Log::Severity::Debug, BACKEND)
    BACKEND.entries.clear
    yield
    BACKEND.entries.compact_map do |entry|
      message = entry.message.gsub(/\e\[[0-9;]*m/, "")
      message if message =~ /\A\[[^\]]*\]\s+(INSERT|UPDATE|DELETE)\b/i
    end
  end
end
