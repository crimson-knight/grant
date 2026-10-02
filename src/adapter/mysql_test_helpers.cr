class Grant::Adapter::Mysql < Grant::Adapter::Base
  protected def truncate_statements(names : Array(String)) : Array(String)
    names.map { |name| "TRUNCATE TABLE #{quote(name)}" }
  end

  def reset_pk_sequence!(table_name : String, primary_key : String = "id") : Nil
    highest_query = "SELECT COALESCE(MAX(#{quote(primary_key)}), 0) + 1 FROM #{quote(table_name)}"
    next_id = open(highest_query) { |conn| conn.scalar(highest_query) }.to_s.to_i64
    statement = "ALTER TABLE #{quote(table_name)} AUTO_INCREMENT = #{next_id}"
    open(statement) { |conn| conn.exec(statement) }
  end

  protected def referential_integrity_off_sql : String
    "SET FOREIGN_KEY_CHECKS = 0"
  end

  protected def referential_integrity_on_sql : String?
    "SET FOREIGN_KEY_CHECKS = 1"
  end

  # crystal-mysql's prepared-statement protocol does not carry session
  # control statements.
  protected def exec_control_statement(statement : String) : Nil
    open { |conn| conn.unprepared.exec(statement) }
  end
end
