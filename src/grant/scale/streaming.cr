module Grant::Scale::Streaming
  # Class-level streaming entrypoint, included into every model so you can write
  # `Model.each_streamed { ... }` without first building a query.
  module ClassMethods
    # Streams every row of the model, yielding one hydrated record at a time
    # directly off the adapter result set, and returns `Nil`.
    #
    # Respects the model's current scope — including the `multitenant` default
    # scope — exactly as `Model.all` does, by routing through `current_scope`.
    # Delegates to the `Query::Builder#each_streamed` terminal, so the same
    # memory characteristics and caveats apply (no eager-loaded associations;
    # use `find_each` if you need those).
    #
    # ```
    # User.each_streamed do |user|
    #   process(user) # all rows, one hydrated record at a time
    # end
    # ```
    def each_streamed(& : self ->) : Nil
      scope = responds_to?(:current_scope) ? current_scope : __builder
      scope.each_streamed { |record| yield record }
    end
  end
end

class Grant::Query::Builder(Model)
  # Streams the relation, hydrating and yielding one record at a time directly
  # from the adapter's `DB::ResultSet` WITHOUT materializing the full Array.
  #
  # Use this for a single, unbounded forward pass over a very large result set
  # where holding every row in memory would be prohibitive. For chunked,
  # resumable iteration that is safe across long-running writes, prefer keyset
  # `in_batches` / `find_each` instead.
  #
  # Eager-loading associations is NOT supported here (that requires collecting
  # the full set first); use `find_each` if you need associations preloaded.
  # Index-hint safe fallback still applies.
  #
  # ```
  # User.where(tenant_id: t).each_streamed do |user|
  #   process(user) # hydrated one row at a time
  # end
  # ```
  def each_streamed(& : Model ->) : Nil
    return if is_none?

    with_index_hint_fallback do |q|
      q.stream_rows { |record| yield record }
    end
  end

  # Runs the SELECT and yields one hydrated `Model` per row off the live result
  # set, returning `Nil`.
  #
  # A single assembler instance builds both the SQL and its bound parameters so
  # they stay in sync. The connection is held open only for the duration of the
  # iteration. `protected` — the public entrypoint is `#each_streamed` (which
  # wraps this with index-hint safe fallback); call that instead.
  #
  # ```
  # # internal use within Query::Builder#each_streamed:
  # with_index_hint_fallback do |q|
  #   q.stream_rows { |record| yield record }
  # end
  # ```
  protected def stream_rows(& : Model ->) : Nil
    a = assembler
    built = a.select # populates a.numbered_parameters via the WHERE build
    sql = built.raw_sql
    params = a.numbered_parameters

    Grant::Logs::SQL.debug { "Streaming query - #{sql} [#{Model.name}]" }

    Model.adapter.open do |db|
      db.query(sql, args: params) do |rs|
        rs.each do
          yield Model.from_rs(rs)
        end
      end
    end
  end
end
