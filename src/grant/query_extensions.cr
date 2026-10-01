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
    return DB::ExecResult.new(0_i64, 0_i64) if is_none?

    Model.guard_writes!

    if should_chunk_in? && (@limit || @offset)
      raise ArgumentError.new("Bulk writes with a chunked IN list cannot preserve limit or offset")
    end

    # Capture a single assembler instance: building the WHERE clause populates
    # its numbered_parameters, which must be bound when the statement runs.
    string_assembler = assembler
    sql = Grant::QueryLogs.append(string_assembler.update_all_fragment_sql(assignments))
    Model.mark_write_operation

    adapter = Model.adapter
    adapter.open(sql, string_assembler.numbered_parameters, Model.name) do |db|
      db.exec(sql, args: adapter.normalize_bind_values(string_assembler.numbered_parameters))
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
  # Returns the number of rows affected. When a `where(col: array)` exceeds the
  # IN-list chunk limit, the conditions are chunked and each UPDATE runs in a
  # single transaction (see `chunked_update_all`); the summed rows_affected is
  # returned.
  def update_all(assignments : Array(Tuple(String, Grant::Columns::Type))) : Int64
    return 0_i64 if is_none?
    return 0_i64 if assignments.empty?

    Model.guard_writes!

    if should_chunk_in? && (@limit || @offset)
      raise ArgumentError.new("Bulk writes with a chunked IN list cannot preserve limit or offset")
    end

    if should_chunk_in?
      return chunked_update_all(assignments)
    end

    update_all_single(assignments)
  end

  # Executes a single UPDATE (no IN-chunking). Used by the chunked path and
  # directly when no chunking is needed.
  protected def update_all_single(assignments : Array(Tuple(String, Grant::Columns::Type))) : Int64
    return 0_i64 if assignments.empty?
    Model.mark_write_operation

    builder_assembler = assembler
    sql = Grant::QueryLogs.append(builder_assembler.update_all_sql(assignments))
    params = builder_assembler.numbered_parameters

    adapter = Model.adapter
    adapter.open(sql, params, Model.name) do |db|
      db.exec(sql, args: adapter.normalize_bind_values(params)).rows_affected
    end
  end
end
