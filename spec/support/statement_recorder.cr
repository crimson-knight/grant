require "log/spec"

# Records every SQL statement the database driver executes while a block runs,
# whichever Grant code path issued it (selects, inserts, updates, deletes,
# transaction control). crystal-db reports each statement at debug level under
# the "db.*" sources.
module StatementRecorder
  # The statement texts, in execution order.
  def self.statements(&) : Array(String)
    backend = Log::MemoryBackend.new
    Log.builder.bind("db.*", Log::Severity::Debug, backend)
    begin
      yield
    ensure
      Log.builder.unbind("db.*", Log::Severity::Debug, backend)
    end
    backend.entries.compact_map { |entry| entry.data[:query]?.try(&.as_s?) }
  end

  # How many recorded statements start with *verb* (case-insensitive), for
  # example `"INSERT INTO"`, optionally mentioning *table*.
  def self.count(statements : Array(String), verb : String, table : String? = nil) : Int32
    statements.count do |sql|
      sql.lstrip.upcase.starts_with?(verb.upcase) && (table.nil? || sql.includes?(table))
    end
  end
end
