module Grant
  # Raised by the batching methods when `error_on_ignore: true` is set and the
  # relation carries an ORDER BY that an explicit `cursor:` overrides.
  class BatchOptionIgnoredError < ErrorBase
  end
end

# What a batch scan needs to know, resolved once from the relation and the
# caller's options: the cursor columns (with their sort directions), the
# inclusive `start`/`finish` bounds, and the relation's own limit and offset.
#
# :nodoc:
struct Grant::Query::BatchPlan
  getter size : Int32
  getter fields : Array(String)
  getter ascending : Array(Bool)
  getter start : Grant::Columns::Type
  getter finish : Grant::Columns::Type
  getter bound_index : Int32
  getter limit : Int64?
  getter offset : Int64?

  def initialize(@size, @fields, @ascending, @start, @finish, @bound_index, @limit, @offset)
  end

  # The column names as models store them (without any table qualifier).
  def columns : Array(String)
    fields.map { |field| field.split('.').last }
  end
end

# Where a batch scan stands: the cursor values of the last row seen, how many
# rows of the relation's own limit remain, and whether the scan has ended.
#
# :nodoc:
class Grant::Query::BatchPosition
  property last_values : Array(Grant::Columns::Type)?
  property remaining : Int64?
  property? started : Bool = false
  property? finished : Bool = false

  def initialize(plan : Grant::Query::BatchPlan)
    @remaining = plan.limit
  end
end

# Lazy form of `find_in_batches`: each call to `next` runs one keyset query,
# so no batch is loaded before it is asked for.
#
# :nodoc:
class Grant::Query::RecordBatchIterator(Model)
  include Iterator(Array(Model))

  def initialize(@relation : Grant::Query::Builder(Model), @plan : Grant::Query::BatchPlan)
    @position = Grant::Query::BatchPosition.new(@plan)
  end

  def next
    if records = @relation.next_batch_records(@plan, @position)
      records
    else
      stop
    end
  end

  def rewind
    @position = Grant::Query::BatchPosition.new(@plan)
    self
  end
end

# Lazy form of `in_batches`: each call to `next` runs one keyset query and
# returns the relation over that batch.
#
# :nodoc:
class Grant::Query::RelationBatchIterator(Model)
  include Iterator(Grant::Query::Builder(Model))

  def initialize(@relation : Grant::Query::Builder(Model), @plan : Grant::Query::BatchPlan, @load : Bool)
    @position = Grant::Query::BatchPosition.new(@plan)
  end

  def next
    if batch = @relation.next_batch_relation(@plan, @position, @load)
      batch
    else
      stop
    end
  end

  def rewind
    @position = Grant::Query::BatchPosition.new(@plan)
    self
  end
end

# Keyset-paginated iteration over a relation, plus per-record `update` and
# `destroy_all`. Every path pages with a `WHERE (cursor columns) > (last seen)`
# predicate and never with OFFSET, so the cost of a page does not grow with the
# number of rows already visited. The relation's own OFFSET, if any, applies to
# the first page only.
module Grant::Query::Batches(Model)
  DEFAULT_BATCH_SIZE = 1000

  # Yields the matching records in batches of at most *batch_size*.
  #
  # The cursor is the relation's ORDER BY columns followed by the primary key,
  # or, for an unordered relation, the model's implicit order columns. Pass
  # *cursor* to page by other columns (they must together identify a row);
  # the relation's ORDER BY is then ignored, and `error_on_ignore: true` raises
  # `Grant::BatchOptionIgnoredError` instead of ignoring it. *start* and
  # *finish* are inclusive bounds on the primary key (or the first cursor
  # column when the primary key is not part of the cursor). *order* is the
  # direction of *cursor* and of an unordered relation. The relation's LIMIT
  # caps the total number of records; the relation itself is never mutated.
  #
  # ```
  # User.where(active: true).find_in_batches(batch_size: 500) do |batch|
  #   bulk_process(batch)
  # end
  # ```
  def find_in_batches(batch_size : Int32 = DEFAULT_BATCH_SIZE, start : Grant::Columns::Type = nil, finish : Grant::Columns::Type = nil, cursor : Array(Symbol)? = nil, order : Symbol = :asc, error_on_ignore : Bool = false, & : Array(Model) ->) : Nil
    return if is_none?

    plan = batch_plan(batch_size, start, finish, cursor, order, error_on_ignore)
    position = Grant::Query::BatchPosition.new(plan)
    while batch = next_batch_records(plan, position)
      yield batch
    end
  end

  # Without a block, returns an iterator that runs one query per batch as it
  # is consumed.
  def find_in_batches(batch_size : Int32 = DEFAULT_BATCH_SIZE, start : Grant::Columns::Type = nil, finish : Grant::Columns::Type = nil, cursor : Array(Symbol)? = nil, order : Symbol = :asc, error_on_ignore : Bool = false) : Iterator(Array(Model))
    plan = batch_plan(batch_size, start, finish, cursor, order, error_on_ignore)
    Grant::Query::RecordBatchIterator(Model).new(self, plan)
  end

  # Yields every matching record, loading them in keyset-paged batches. Takes
  # the same options as `find_in_batches`.
  #
  # ```
  # User.where(active: true).find_each(batch_size: 500) do |user|
  #   process(user)
  # end
  # ```
  def find_each(batch_size : Int32 = DEFAULT_BATCH_SIZE, start : Grant::Columns::Type = nil, finish : Grant::Columns::Type = nil, cursor : Array(Symbol)? = nil, order : Symbol = :asc, error_on_ignore : Bool = false, & : Model ->) : Nil
    find_in_batches(batch_size, start, finish, cursor, order, error_on_ignore) do |batch|
      batch.each { |record| yield record }
    end
  end

  # Without a block, returns an iterator over the records that fetches one
  # batch at a time.
  def find_each(batch_size : Int32 = DEFAULT_BATCH_SIZE, start : Grant::Columns::Type = nil, finish : Grant::Columns::Type = nil, cursor : Array(Symbol)? = nil, order : Symbol = :asc, error_on_ignore : Bool = false) : Iterator(Model)
    find_in_batches(batch_size, start, finish, cursor, order, error_on_ignore).flat_map { |batch| batch }
  end

  # Yields each batch as a relation scoped to that batch's rows, so
  # `batch.update_all`, `batch.delete_all`, `batch.pluck` and `batch.count`
  # run as one SQL statement per batch.
  #
  # By default (`load: false`) a batch costs one light query that plucks only
  # the key columns; the yielded relation is `WHERE primary_key IN (ids)` on
  # top of the receiver's conditions, in the batch's cursor order. With
  # `load: true` the records are fetched first and the yielded relation is
  # already loaded (iterating it runs no further SQL). Options are those of
  # `find_in_batches`, with *of* naming the batch size.
  #
  # ```
  # User.where(active: false).in_batches(of: 500) do |batch|
  #   batch.update_all(archived: true)
  # end
  # ```
  def in_batches(of batch_size : Int32 = DEFAULT_BATCH_SIZE, start : Grant::Columns::Type = nil, finish : Grant::Columns::Type = nil, load : Bool = false, cursor : Array(Symbol)? = nil, order : Symbol = :asc, error_on_ignore : Bool = false, & : Grant::Query::Builder(Model) ->) : Nil
    return if is_none?

    plan = batch_plan(batch_size, start, finish, cursor, order, error_on_ignore)
    position = Grant::Query::BatchPosition.new(plan)
    while batch = next_batch_relation(plan, position, load)
      yield batch
    end
  end

  # Without a block, returns an iterator over the batch relations.
  def in_batches(of batch_size : Int32 = DEFAULT_BATCH_SIZE, start : Grant::Columns::Type = nil, finish : Grant::Columns::Type = nil, load : Bool = false, cursor : Array(Symbol)? = nil, order : Symbol = :asc, error_on_ignore : Bool = false) : Iterator(Grant::Query::Builder(Model))
    plan = batch_plan(batch_size, start, finish, cursor, order, error_on_ignore)
    Grant::Query::RelationBatchIterator(Model).new(self, plan, load)
  end

  # Loads each matching record and calls `destroy` on it, so destroy
  # callbacks and `dependent:` handling run. Records are read in keyset
  # batches of 1000 and each batch is destroyed in one transaction; a
  # `dependent: :restrict` record aborts its own destroy and is skipped, while
  # an exception (such as `restrict_with_exception`) rolls back the batch in
  # progress and propagates. Returns the records that were destroyed.
  #
  # ```
  # User.where(active: false).destroy_all_records # => [#<User ...>, ...]
  # ```
  def destroy_all_records : Array(Model)
    Model.guard_writes!
    destroyed = [] of Model
    find_in_batches(DEFAULT_BATCH_SIZE) do |batch|
      Model.transaction do
        batch.each { |record| destroyed << record if record.destroy }
      end
    end
    destroyed
  end

  # Destroys every matching record (see `destroy_all_records`) and returns how
  # many were destroyed.
  #
  # ```
  # User.where(active: false).destroy_all # => 3
  # ```
  def destroy_all : Int32
    destroy_all_records.size
  end

  # Updates every matching record one at a time through `record.update`, so
  # validations and callbacks run. Returns all matched records, including any
  # whose update failed (check `errors` on them), like ActiveRecord. Records
  # are read in keyset batches and each batch is written in one transaction.
  #
  # ```
  # User.where(active: false).update(active: true)
  # ```
  def update(**attributes) : Array(Model)
    update_each(attributes, false)
  end

  # Like `update`, but raises `Grant::RecordInvalid` or `Grant::RecordNotSaved`
  # for the first record that cannot be saved; that record's batch is rolled
  # back.
  def update!(**attributes) : Array(Model)
    update_each(attributes, true)
  end

  # Updates the record with primary key *id* inside this relation and returns
  # it. Raises `Grant::Querying::NotFound` when the relation has no such row.
  #
  # ```
  # User.where(active: true).update(1, name: "Ada")
  # ```
  def update(id : Grant::Columns::Type, **attributes) : Model
    record = find_in_relation(id)
    record.update(attributes)
    record
  end

  # Like `update(id, **attributes)`, but raises when the save fails.
  def update!(id : Grant::Columns::Type, **attributes) : Model
    record = find_in_relation(id)
    record.update!(attributes)
    record
  end

  private def find_in_relation(id : Grant::Columns::Type) : Model
    Model.guard_writes!
    key = Model.primary_name
    where(key, :eq, id).first? || raise Grant::Querying::NotFound.new("No #{Model.name} found where #{key} = #{id}")
  end

  private def update_each(attributes, bang : Bool) : Array(Model)
    Model.guard_writes!
    updated = [] of Model
    each_batch_for_update do |batch|
      Model.transaction do
        batch.each do |record|
          bang ? record.update!(attributes) : record.update(attributes)
          updated << record
        end
      end
    end
    updated
  end

  # Yields the relation's records in batches of `DEFAULT_BATCH_SIZE` for a
  # per-record update. When the cursor is only the key columns, this is a
  # keyset scan. When it includes other columns (an ORDER BY or an implicit
  # order column), an update can move an already-updated row past the cursor,
  # where a keyset scan would load and update it again; so the keys are
  # snapshotted first (one query that plucks only the key columns, honoring
  # the relation's order, limit and offset) and each batch is loaded by key.
  private def each_batch_for_update(& : Array(Model) ->) : Nil
    return if is_none?

    plan = batch_plan(DEFAULT_BATCH_SIZE, nil, nil, nil, :asc, false)
    identity_columns = key_columns
    if plan.columns.all? { |column| identity_columns.includes?(column) }
      find_in_batches(DEFAULT_BATCH_SIZE) { |batch| yield batch }
      return
    end

    snapshot = dup
    snapshot.clear_order_fields
    apply_batch_order(snapshot, plan)
    snapshot_assembler = snapshot.assembler
    identities = Grant::Query::Executor::Pluck(Model).new(snapshot_assembler.pluck_sql(identity_columns), snapshot_assembler.numbered_parameters, identity_columns).run
    identities.each_slice(DEFAULT_BATCH_SIZE) do |slice|
      records = batch_relation(plan, slice).select
      yield records unless records.empty?
    end
  end

  # Resolves the cursor, bounds and paging options into a plan.
  #
  # :nodoc:
  def batch_plan(batch_size : Int32, start : Grant::Columns::Type, finish : Grant::Columns::Type, cursor : Array(Symbol)?, order : Symbol, error_on_ignore : Bool) : Grant::Query::BatchPlan
    raise ArgumentError.new("batch_size must be >= 1") unless batch_size >= 1
    raise ArgumentError.new("order must be :asc or :desc, got #{order.inspect}") unless order == :asc || order == :desc

    descending = order == :desc
    fields = [] of String
    ascending = [] of Bool

    if requested = cursor
      raise ArgumentError.new("cursor must name at least one column") if requested.empty?
      if error_on_ignore && !order_fields.empty?
        raise Grant::BatchOptionIgnoredError.new("cursor: overrides the ORDER BY of this #{Model.name} relation")
      end
      requested.each do |column|
        fields << column.to_s
        ascending << !descending
      end
    elsif !order_fields.empty?
      order_fields.each do |field|
        fields << field[:field]
        ascending << (field[:direction] == Grant::Query::Builder::Sort::Ascending)
      end
      key_columns.each do |column|
        next if fields.any? { |field| field.split('.').last == column }
        fields << column
        ascending << true
      end
    else
      implicit_order_columns.each do |column|
        fields << column
        ascending << !descending
      end
    end

    primary = Model.primary_name
    bound_index = fields.index { |field| field.split('.').last == primary } || 0
    Grant::Query::BatchPlan.new(batch_size, fields, ascending, start, finish, bound_index, limit, offset)
  end

  # Fetches the next page of records, or `nil` once the scan is over.
  #
  # :nodoc:
  def next_batch_records(plan : Grant::Query::BatchPlan, position : Grant::Query::BatchPosition) : Array(Model)?
    page_size = next_page_size(plan, position)
    return unless page_size

    records = batch_page(plan, position, page_size).select
    advance_batch_position(plan, position, page_size, records.size, records.last?.try { |last| cursor_values_of(plan, last) })
    records.empty? ? nil : records
  end

  # Fetches the next page as a relation over just that page's rows, or `nil`
  # once the scan is over.
  #
  # :nodoc:
  def next_batch_relation(plan : Grant::Query::BatchPlan, position : Grant::Query::BatchPosition, load : Bool) : Grant::Query::Builder(Model)?
    if load
      records = next_batch_records(plan, position)
      return unless records
      identities = records.map do |record|
        identity = [] of Grant::Columns::Type
        key_columns.each { |column| identity << record.read_attribute(column) }
        identity
      end
      relation = batch_relation(plan, identities)
      relation.memoized_records = records
      return relation
    end

    page_size = next_page_size(plan, position)
    return unless page_size

    columns = plan.columns
    identity_columns = key_columns
    names = (columns + identity_columns).uniq
    page = batch_page(plan, position, page_size)
    page_assembler = page.assembler
    rows = Grant::Query::Executor::Pluck(Model).new(page_assembler.pluck_sql(names), page_assembler.numbered_parameters, names).run
    last_values = rows.last?.try do |row|
      cursor = [] of Grant::Columns::Type
      columns.each { |column| cursor << row[names.index!(column)] }
      cursor
    end
    advance_batch_position(plan, position, page_size, rows.size, last_values)
    return if rows.empty?

    identities = rows.map do |row|
      identity = [] of Grant::Columns::Type
      identity_columns.each { |column| identity << row[names.index!(column)] }
      identity
    end
    batch_relation(plan, identities)
  end

  # :nodoc:
  protected def memoized_records=(records : Array(Model))
    @records = records
  end

  private def next_page_size(plan : Grant::Query::BatchPlan, position : Grant::Query::BatchPosition) : Int32?
    # A `none` relation matches nothing, including through the lazy iterator
    # forms, which do not pass through the block forms' early return.
    return nil if position.finished? || is_none?
    remaining = position.remaining
    return nil if remaining && remaining <= 0
    remaining ? Math.min(plan.size.to_i64, remaining).to_i32 : plan.size
  end

  private def advance_batch_position(plan : Grant::Query::BatchPlan, position : Grant::Query::BatchPosition, page_size : Int32, fetched : Int32, last_values : Array(Grant::Columns::Type)?) : Nil
    position.started = true
    position.last_values = last_values
    if remaining = position.remaining
      position.remaining = remaining - fetched
    end
    position.finished = true if fetched < page_size || last_values.nil?
    if remaining = position.remaining
      position.finished = true if remaining <= 0
    end
  end

  private def cursor_values_of(plan : Grant::Query::BatchPlan, record : Model) : Array(Grant::Columns::Type)
    values = [] of Grant::Columns::Type
    plan.columns.each do |column|
      value = record.read_attribute(column)
      raise ArgumentError.new("Cannot batch #{Model.name} by #{column}: a row has NULL there") if value.nil?
      values << value
    end
    values
  end

  # The relation that selects one page: the receiver's conditions, the bounds,
  # the keyset predicate for everything after the last row, and the cursor as
  # ORDER BY.
  private def batch_page(plan : Grant::Query::BatchPlan, position : Grant::Query::BatchPosition, page_size : Int32) : self
    page = dup
    page.clear_order_fields
    apply_batch_order(page, plan)
    page.limit!(page_size)
    page.offset!(position.started? ? nil : plan.offset)

    if bound = plan.start
      page.and!(plan.fields[plan.bound_index], plan.ascending[plan.bound_index] ? :gteq : :lteq, bound)
    end
    if bound = plan.finish
      page.and!(plan.fields[plan.bound_index], plan.ascending[plan.bound_index] ? :lteq : :gteq, bound)
    end

    if last = position.last_values
      statement, values = keyset_condition(plan, last)
      page.and!(statement, values)
    end

    page
  end

  private def apply_batch_order(target : Grant::Query::Builder(Model), plan : Grant::Query::BatchPlan) : Nil
    plan.fields.each_with_index do |field, index|
      sort = plan.ascending[index] ? Grant::Query::Builder::Sort::Ascending : Grant::Query::Builder::Sort::Descending
      target.own_order_fields << {field: field, direction: sort}
    end
  end

  # `(a > ?) OR (a = ? AND b > ?) ...`: rows strictly after *last* in the
  # cursor order, with a direction per column.
  private def keyset_condition(plan : Grant::Query::BatchPlan, last : Array(Grant::Columns::Type)) : {String, Array(Grant::Columns::Type)}
    alternatives = [] of String
    values = [] of Grant::Columns::Type
    plan.fields.each_index do |index|
      terms = [] of String
      index.times do |earlier|
        terms << "#{structured_field_sql(plan.fields[earlier])} = ?"
        values << last[earlier]
      end
      terms << "#{structured_field_sql(plan.fields[index])} #{plan.ascending[index] ? ">" : "<"} ?"
      values << last[index]
      alternatives << "(#{terms.join(" AND ")})"
    end
    {"(#{alternatives.join(" OR ")})", values}
  end

  # The relation handed to `in_batches`: the receiver's conditions narrowed to
  # the page's rows, in cursor order, without limit or offset.
  private def batch_relation(plan : Grant::Query::BatchPlan, identities : Array(Array(Grant::Columns::Type))) : Grant::Query::Builder(Model)
    relation = dup
    relation.clear_order_fields
    apply_batch_order(relation, plan)
    relation.limit!(nil)
    relation.offset!(nil)

    identity_columns = key_columns
    values = [] of Grant::Columns::Type
    if identity_columns.size == 1
      identities.each { |identity| values << identity.first }
      placeholders = Array.new(values.size, "?").join(", ")
      relation.and!("#{structured_field_sql(identity_columns.first)} IN (#{placeholders})", values)
    else
      match = "(#{identity_columns.map { |column| "#{structured_field_sql(column)} = ?" }.join(" AND ")})"
      identities.each { |identity| identity.each { |value| values << value } }
      relation.and!("(#{Array.new(identities.size, match).join(" OR ")})", values)
    end
    relation
  end
end
