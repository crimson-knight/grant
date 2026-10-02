class Grant::Adapter::Sqlite < Grant::Adapter::Base
  # Deletes the rows and forgets the AUTOINCREMENT counters of *names*.
  protected def truncate_statements(names : Array(String)) : Array(String)
    statements = super
    if autoincrement_counters?
      names.each { |name| statements << "DELETE FROM sqlite_sequence WHERE name = #{quote_string(name)}" }
    end
    statements
  end

  def reset_pk_sequence!(table_name : String, primary_key : String = "id") : Nil
    return unless autoincrement_counters?

    highest_query = "SELECT COALESCE(MAX(#{quote(primary_key)}), 0) FROM #{quote(table_name)}"
    highest = open(highest_query) { |conn| conn.scalar(highest_query) }
    statement = "UPDATE sqlite_sequence SET seq = ? WHERE name = ?"
    open(statement, [highest.to_s.to_i64, table_name]) do |conn|
      conn.exec(statement, highest.to_s.to_i64, table_name)
    end
  end

  # Foreign keys cannot be toggled inside a transaction; deferring them to the
  # commit is the SQLite equivalent and resets by itself.
  protected def referential_integrity_off_sql : String
    "PRAGMA defer_foreign_keys = ON"
  end

  protected def referential_integrity_on_sql : String?
    "PRAGMA defer_foreign_keys = OFF"
  end

  # `sqlite_sequence` exists only once a table declared AUTOINCREMENT.
  private def autoincrement_counters? : Bool
    query = "SELECT 1 FROM sqlite_master WHERE name = 'sqlite_sequence'"
    !open(query) { |conn| conn.query_one?(query, as: Int64) }.nil?
  end

  private def quote_string(value : String) : String
    "'#{value.gsub("'", "''")}'"
  end
end
