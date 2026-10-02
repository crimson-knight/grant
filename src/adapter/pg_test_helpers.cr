class Grant::Adapter::Pg < Grant::Adapter::Base
  # One `TRUNCATE` for every table, restarting sequences and emptying the
  # tables that reference them.
  def truncate_tables(names : Array(String)) : Nil
    return if names.empty?
    statement = "TRUNCATE TABLE #{names.join(", ") { |name| quote(name) }} RESTART IDENTITY CASCADE"
    open(statement, &.exec(statement))
  end

  def reset_pk_sequence!(table_name : String, primary_key : String = "id") : Nil
    sequence = open { |conn| conn.scalar("SELECT pg_get_serial_sequence($1, $2)", quote(table_name), primary_key) }
    return unless sequence.is_a?(String)

    statement = "SELECT setval($1::regclass, COALESCE(MAX(#{quote(primary_key)}), 0) + 1, false) FROM #{quote(table_name)}"
    open(statement, [sequence]) { |conn| conn.scalar(statement, sequence) }
  end

  # `SET LOCAL` ends with the transaction that `disable_referential_integrity`
  # opened, so only a joined outer transaction needs the explicit restore.
  protected def referential_integrity_off_sql : String
    "SET LOCAL session_replication_role = replica"
  end

  protected def referential_integrity_on_sql : String?
    "SET LOCAL session_replication_role = origin"
  end
end
