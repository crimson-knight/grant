class Grant::Query::Builder(Model)
  # Per-query override of `Grant.settings.in_clause_limit`. When set, a
  # `where(col: array)` whose array exceeds this size is split into chunks of
  # this many values instead of the global default.
  @in_chunk_size : Int32? = nil

  # Overrides the IN-list chunk size for this query, returning `self` to chain.
  #
  # When a `where(col: array)` carries more values than *size*, Grant
  # transparently splits it into multiple queries of at most *size* values each
  # and stitches the results back together (avoiding adapter IN-list limits and
  # huge single statements). Without this call the global
  # `Grant.settings.in_clause_limit` is used. Raises `ArgumentError` if *size*
  # is not positive.
  #
  # ```
  # # split a 10_000-element IN list into queries of 500 values each
  # User.where(id: huge_array).in_chunks(of: 500).to_a
  # ```
  def in_chunks(of size : Int32) : self
    raise ArgumentError.new("in_chunks size must be positive") if size <= 0
    @in_chunk_size = size
    self
  end

  # The effective IN-chunk size (per-query override or global setting).
  protected def effective_in_chunk_size : Int32
    @in_chunk_size || Grant.settings.in_clause_limit
  end

  # Copies large-table toolkit state (currently the per-query IN-chunk override)
  # from *other* into self. Called by `Builder#dup` so a duped query keeps its
  # `.in_chunks(of:)` setting.
  protected def copy_scale_state_from(other : self)
    @in_chunk_size = other.in_chunk_size_value
  end

  # Internal accessor for the per-query chunk override (used by `copy_scale_state_from`).
  protected def in_chunk_size_value : Int32?
    @in_chunk_size
  end

  # Index into `@where_fields` of the FIRST `:in` clause whose value array
  # exceeds the chunk size, or nil if no chunking is needed. We chunk a single
  # oversized IN list (the documented, common large-table case); other WHERE
  # conditions are replayed verbatim on every chunk.
  protected def oversized_in_index : Int32?
    limit = effective_in_chunk_size
    @where_fields.each_with_index do |field, idx|
      if field.is_a?(NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type))
        op = field[:operator]
        val = field[:value]
        if (op == :in || op == :nin) && val.is_a?(Array) && val.size > limit
          # NOT IN cannot be chunked by union (would change semantics), so only
          # chunk plain IN. NOT IN over a huge list is rare; let it fall through.
          return idx if op == :in
        end
      end
    end
    nil
  end

  # Returns `true` when this query will be executed as chunked IN queries —
  # i.e. some `where(col: array)` carries more values than the effective chunk
  # limit (`#in_chunks` override or `Grant.settings.in_clause_limit`). Public for
  # introspection and testing; terminals consult it to decide whether to dispatch
  # to the chunked path.
  #
  # ```
  # User.where(id: [1, 2, 3]).should_chunk_in?                   # => false
  # User.where(id: huge_array).in_chunks(of: 2).should_chunk_in? # => true
  # ```
  def should_chunk_in? : Bool
    !oversized_in_index.nil?
  end

  # Yields one builder per chunk: a dup of this query with the oversized IN
  # array replaced by the chunk slice. The dup drops limit/offset (the caller
  # re-imposes limit across chunks) and any per-chunk overrides as needed.
  protected def each_in_chunk(&)
    idx = oversized_in_index
    return unless idx

    base_field = @where_fields[idx].as(NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type))
    full_values = base_field[:value].as(Array)
    chunk_size = effective_in_chunk_size

    Grant::Logs::Query.debug do
      "IN-list chunking engaged for #{Model.name}.#{base_field[:field]}: " \
      "#{full_values.size} values in chunks of #{chunk_size}"
    end

    full_values.each_slice(chunk_size) do |slice|
      chunk_query = dup
      # Rebuild the where_fields array on the dup, swapping just the oversized IN.
      new_fields = chunk_query.where_fields.map_with_index do |f, i|
        if i == idx
          {join: base_field[:join], field: base_field[:field], operator: :in, value: slice.as(Grant::Columns::Type)}.as(WhereField)
        else
          f
        end
      end
      chunk_query.where_fields.clear
      new_fields.each { |f| chunk_query.where_fields << f }
      yield chunk_query
    end
  end

  # ---- Chunked read terminals ------------------------------------------------

  # Runs the SELECT one chunk at a time and returns the combined
  # `Array(Model)`, de-duplicated by primary key and honoring ORDER + LIMIT
  # across chunk boundaries.
  #
  # When ORDER is set, results are merged in-memory with a stable sort so the
  # global ordering is correct across chunks — this costs O(total) memory for the
  # merged set. When LIMIT is set, collection stops early once enough rows are
  # gathered (after the merge, since the order must be global). `protected` —
  # invoked automatically by terminals like `#to_a`/`#select` when
  # `#should_chunk_in?` is true; you do not call it directly.
  #
  # ```
  # # transparently dispatched by a normal terminal call:
  # users = User.where(id: huge_array).in_chunks(of: 500).order(:name).to_a
  # # => Array(User), globally ordered and de-duplicated
  # ```
  protected def chunked_select : Array(Model)
    requested_limit = @limit
    has_order = !@order_fields.empty?

    collected = [] of Model
    seen = Set(Grant::Columns::Type).new
    pk = Model.primary_name

    each_in_chunk do |chunk_query|
      # Drop offset on chunks (offset across chunks is ambiguous; applied last).
      chunk_query.offset(nil)
      # If a limit is set, each chunk need only fetch up to that many rows when
      # there is no global ordering (early-stop optimization). With ordering we
      # must fetch each chunk's limit-worth to merge correctly.
      if requested_limit
        chunk_query.limit(requested_limit)
      else
        chunk_query.limit(nil)
      end

      records = chunk_query.select_single
      records.each do |record|
        key = record.read_attribute(pk)
        next if seen.includes?(key)
        seen << key
        collected << record
      end

      # Fast path: no order, limit satisfied -> stop scanning further chunks.
      if requested_limit && !has_order && collected.size >= requested_limit
        break
      end
    end

    if has_order
      collected = merge_sort_records(collected)
    end

    if requested_limit
      collected = collected[0, requested_limit]
    end

    collected
  end

  # Chunked COUNT: sums per-chunk counts.
  #
  # NOTE: this is exact only when the chunked IN values are unique AND the query
  # is not `DISTINCT` across an overlapping projection. Because IN-list chunks
  # partition the value set, rows are not double-counted for a plain
  # `COUNT(*)` over a single oversized IN column. For `DISTINCT` counts across
  # chunks, prefer `ids` (which de-duplicates) and count the result.
  protected def chunked_count : Int64
    total = 0_i64
    each_in_chunk do |chunk_query|
      chunk_query.limit(nil)
      chunk_query.offset(nil)
      total += chunk_query.count_single
    end
    total
  end

  # Chunked ids: concatenates and de-duplicates primary keys across chunks.
  protected def chunked_ids : Array(Grant::Columns::Type)
    seen = Set(Grant::Columns::Type).new
    result = [] of Grant::Columns::Type
    each_in_chunk do |chunk_query|
      chunk_query.limit(nil)
      chunk_query.offset(nil)
      chunk_query.ids_single.each do |id|
        next if seen.includes?(id)
        seen << id
        result << id
      end
    end
    result
  end

  # Runs `pluck` one chunk at a time and concatenates the per-chunk rows into a
  # single `Array(Array(Grant::Columns::Type))` (one inner array per row, one
  # element per requested field).
  #
  # No de-duplication is performed — `pluck` is row-level, so identical rows are
  # preserved. `protected` — dispatched automatically by `#pluck` when the query
  # carries an oversized IN list; you do not call it directly.
  #
  # ```
  # # transparently dispatched by Query::Builder#pluck:
  # rows = User.where(id: huge_array).in_chunks(of: 500).pluck("id", "email")
  # # => [[1, "a@x.com"], [2, "b@x.com"], ...]
  # ```
  protected def chunked_pluck(field_names : Array(String)) : Array(Array(Grant::Columns::Type))
    result = [] of Array(Grant::Columns::Type)
    each_in_chunk do |chunk_query|
      chunk_query.limit(nil)
      chunk_query.offset(nil)
      result.concat(chunk_query.pluck_single(field_names))
    end
    result
  end

  # ---- Chunked write terminals -----------------------------------------------

  # Chunked UPDATE: runs one UPDATE per chunk inside a single transaction and
  # returns the summed rows_affected.
  protected def chunked_update_all(assignments : Array(Tuple(String, Grant::Columns::Type))) : Int64
    total = 0_i64
    Model.transaction do
      each_in_chunk do |chunk_query|
        chunk_query.limit(nil)
        chunk_query.offset(nil)
        total += chunk_query.update_all_single(assignments)
      end
    end
    total
  end

  # Chunked DELETE: runs one DELETE per chunk inside a single transaction and
  # returns the summed rows_affected.
  protected def chunked_delete_all : Int64
    total = 0_i64
    Model.transaction do
      each_in_chunk do |chunk_query|
        chunk_query.limit(nil)
        chunk_query.offset(nil)
        total += chunk_query.delete_all_single
      end
    end
    total
  end

  # Stable in-memory sort honoring the query's ORDER fields, used to merge
  # ordered results across IN chunks. Supports multi-column order with mixed
  # ASC/DESC directions; nil sorts last for ASC, first for DESC (SQL default-ish).
  private def merge_sort_records(records : Array(Model)) : Array(Model)
    fields = @order_fields
    records.sort do |a, b|
      cmp = 0
      fields.each do |of|
        va = a.read_attribute(of[:field])
        vb = b.read_attribute(of[:field])
        c = compare_values(va, vb)
        c = -c if of[:direction] == Grant::Query::Builder::Sort::Descending
        if c != 0
          cmp = c
          break
        end
      end
      cmp
    end
  end

  private def compare_values(a : Grant::Columns::Type, b : Grant::Columns::Type) : Int32
    return 0 if a.nil? && b.nil?
    return 1 if a.nil? # nils last (ASC)
    return -1 if b.nil?

    # Numeric comparison when both are numbers (covers Int*/Float* mix).
    if a.is_a?(Number) && b.is_a?(Number)
      af = a.to_f
      bf = b.to_f
      return af < bf ? -1 : (af > bf ? 1 : 0)
    end

    if a.is_a?(Time) && b.is_a?(Time)
      return a < b ? -1 : (a > b ? 1 : 0)
    end

    if a.is_a?(String) && b.is_a?(String)
      return a < b ? -1 : (a > b ? 1 : 0)
    end

    # Mixed / unsupported types: fall back to string comparison for determinism.
    sa = a.to_s
    sb = b.to_s
    sa < sb ? -1 : (sa > sb ? 1 : 0)
  end
end
