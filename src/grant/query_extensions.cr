# Query extensions for association options
class Grant::Query::Builder(Model)
  # Updates all matching rows using a raw SQL SET fragment.
  #
  # WARNING: the *assignments* string is interpolated verbatim into the
  # statement. Only use this form with trusted, developer-controlled SQL. For
  # user-supplied values prefer the `Hash`/named-argument forms below, which
  # bind values as parameters.
  #
  # ```
  # User.where(active: false).update_all("login_count = login_count + 1")
  # ```
  def update_all(assignments : String)
    Model.guard_writes!
    # Capture a single assembler instance: building the WHERE clause populates
    # its numbered_parameters, which must be bound when the statement runs.
    string_assembler = assembler
    sql = "UPDATE #{Model.table_name} SET #{assignments}"

    if where_clause = string_assembler.where
      sql += " #{where_clause}"
    end

    Model.adapter.open do |db|
      db.exec(sql, args: string_assembler.numbered_parameters)
    end
  end

  # Updates all matching rows from a Hash of `column => value` assignments,
  # building a safe parameterized `UPDATE ... SET col = ?` statement.
  #
  # Every value is routed through bound parameters (never string-interpolated),
  # so this form is injection-safe for user-supplied data. Returns the number of
  # rows affected.
  #
  # ```
  # User.where(active: false).update_all({"name" => "Anonymous", "active" => true})
  # User.where(id: 5).update_all({:visits => 0})
  # ```
  def update_all(assignments : Hash(String | Symbol, Grant::Columns::Type)) : Int64
    update_all(assignments.map { |k, v| {k.to_s, v.as(Grant::Columns::Type)} })
  end

  # :ditto:
  def update_all(assignments : Hash(String, Grant::Columns::Type)) : Int64
    update_all(assignments.map { |k, v| {k, v.as(Grant::Columns::Type)} })
  end

  # :ditto:
  def update_all(assignments : Hash(Symbol, Grant::Columns::Type)) : Int64
    update_all(assignments.map { |k, v| {k.to_s, v.as(Grant::Columns::Type)} })
  end

  # Updates all matching rows from named arguments.
  #
  # ```
  # User.where(active: false).update_all(name: "Anonymous", active: true)
  # ```
  def update_all(**assignments) : Int64
    pairs = [] of Tuple(String, Grant::Columns::Type)
    assignments.each do |k, v|
      pairs << {k.to_s, v.as(Grant::Columns::Type)}
    end
    update_all(pairs)
  end

  # Core parameterized update: builds and executes a bound UPDATE statement.
  #
  # Returns the number of rows affected.
  def update_all(assignments : Array(Tuple(String, Grant::Columns::Type))) : Int64
    Model.guard_writes!
    return 0_i64 if assignments.empty?
    Model.mark_write_operation

    builder_assembler = assembler
    sql = builder_assembler.update_all_sql(assignments)
    params = builder_assembler.numbered_parameters

    Model.adapter.open do |db|
      db.exec(sql, args: params).rows_affected
    end
  end
end
