# Convenience Methods for Grant ORM
#
# Provides convenience methods for querying and manipulating data,
# including pluck, pick, in_batches, upsert_all, insert_all, and query annotations.
#
# ## Features
#
# - `pluck` - Extract one or more columns from records
# - `pick` - Extract columns from a single record
# - `in_batches` - Process records in batches
# - `upsert_all` - Bulk upsert (insert or update)
# - `insert_all` - Bulk insert with options
# - `annotate` - Add comments to queries for debugging
#
# ## Usage
#
# ```
# # Pluck multiple columns
# User.where(active: true).pluck(:id, :name)
# # => [[1, "John"], [2, "Jane"]]
#
# # Pick from first record
# User.pick(:id, :name)
# # => [1, "John"]
#
# # Process in batches
# User.in_batches(of: 100) do |batch|
#   batch.update_all(processed: true)
# end
#
# # Bulk upsert
# User.upsert_all([
#   {name: "John", email: "john@example.com"},
#   {name: "Jane", email: "jane@example.com"},
# ])
#
# # Annotate queries
# User.where(active: true).annotate("Called from dashboard").select
# ```

module Grant::ConvenienceMethods(Model)
  # Returns the values of the given *fields* for the matching rows, skipping
  # model instantiation.
  #
  # Each result row is an `Array` of the requested column values, in the order
  # the *fields* were given. Because no model objects are built, `pluck` is much
  # cheaper than mapping over `select` when you only need a few columns.
  #
  # *fields* are column names as symbols. Respects the relation's WHERE/ORDER/
  # LIMIT. Routes through IN-list chunking when a `where(col: array)` exceeds the
  # chunk limit; the single-query path is `pluck_single`.
  #
  # Returns `Array(Array(Grant::Columns::Type))` — one inner array per row.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column email : String
  #   column active : Bool
  # end
  #
  # User.where(active: true).pluck(:id, :email)
  # # => [[1, "a@example.com"], [2, "b@example.com"]]
  #
  # # Single column still yields nested arrays:
  # User.all.pluck(:id) # => [[1], [2], [3]]
  # ```
  def pluck(*fields : Symbol) : Array(Array(Grant::Columns::Type))
    field_names = fields.to_a.map(&.to_s)

    if should_chunk_in?
      return chunked_pluck(field_names)
    end

    pluck_single(field_names)
  end

  # Executes a single pluck query from already-stringified field names. Builds a
  # fresh assembler each call so per-chunk parameters do not accumulate.
  protected def pluck_single(field_names : Array(String)) : Array(Array(Grant::Columns::Type))
    assembler = case @db_type
                when Grant::Query::Builder::DbType::Pg
                  Grant::Query::Assembler::Pg(Model).new(self)
                when Grant::Query::Builder::DbType::Mysql
                  Grant::Query::Assembler::Mysql(Model).new(self)
                when Grant::Query::Builder::DbType::Sqlite
                  Grant::Query::Assembler::Sqlite(Model).new(self)
                else
                  raise "Unknown database type: #{@db_type}"
                end

    sql = assembler.pluck_sql(field_names)
    Grant::Query::Executor::Pluck(Model).new(sql, assembler.numbered_parameters, field_names).run
  end

  # Returns the given *fields* from the first matching row, or `nil` if none.
  #
  # Like a single-row `pluck`: it applies `LIMIT 1`, then returns that row's
  # values as a flat `Array` (not nested), or `nil` when the relation is empty.
  #
  # *fields* are column names as symbols.
  #
  # Returns `Array(Grant::Columns::Type)?` — the first row's values, or `nil`.
  #
  # ```
  # User.where(active: true).pick(:id, :email)
  # # => [1, "a@example.com"]
  #
  # User.where(active: false).pick(:id) # => nil  (when no rows match)
  # ```
  def pick(*fields : Symbol) : Array(Grant::Columns::Type)?
    limit(1).pluck(*fields).first?
  end

  # Processes matching records in batches, yielding each batch as an Array.
  #
  # Uses primary-key cursor pagination (not OFFSET), so it stays efficient and
  # stable on large tables even as rows are inserted/deleted during iteration.
  # The caller's relation is never mutated.
  #
  # - *of*: maximum records per batch (default `1000`).
  # - *start* / *finish*: inclusive lower/upper primary-key bounds to scan.
  # - *order*: `:asc` (default) or `:desc` primary-key direction.
  # - *load*, *error_on_ignore*: accepted for ActiveRecord signature parity.
  #
  # Yields each batch as an `Array(Model)`.
  #
  # ```
  # User.where(active: true).in_batches(of: 500) do |batch|
  #   puts "processing #{batch.size} users"
  # end
  #
  # # Only ids 1_000..2_000, newest first:
  # User.all.in_batches(of: 100, start: 1_000, finish: 2_000, order: :desc) do |batch|
  #   batch.each { |u| process(u) }
  # end
  # ```
  def in_batches(of batch_size : Int32 = 1000, start : Int64? = nil, finish : Int64? = nil, load : Bool = false, error_on_ignore : Bool = false, order : Symbol = :asc, &block : Array(Model) -> _)
    ascending = order != :desc
    primary_key = Model.primary_name

    # Build the fixed base relation ONCE: the caller's conditions + a primary-key
    # order + the optional start/finish bounds. We `dup` so the caller's query is
    # never mutated, and so each batch can be derived fresh below. `Builder#where`
    # mutates and returns `self`, so reusing one relation across iterations would
    # stack a new `WHERE pk > ?` predicate every batch (the cursor accumulation
    # bug). Instead we keep a single moving cursor and re-derive per batch.
    base_relation = self.dup
    base_relation = base_relation.order({primary_key => ascending ? :asc : :desc})

    if start
      base_relation = base_relation.where(primary_key, ascending ? :gteq : :lteq, start.as(Grant::Columns::Type))
    end

    if finish
      base_relation = base_relation.where(primary_key, ascending ? :lteq : :gteq, finish.as(Grant::Columns::Type))
    end

    cursor_op = ascending ? :gt : :lt
    cursor_id : Int64? = nil

    loop do
      # Derive this batch from a pristine copy of the base relation and add at
      # most ONE cursor predicate, so the WHERE clause stays constant in size.
      batch_relation = base_relation.dup
      if cid = cursor_id
        batch_relation = batch_relation.where(primary_key, cursor_op, cid)
      end
      records = batch_relation.limit(batch_size).select

      break if records.empty?

      yield records

      break if records.size < batch_size

      cursor_id = records.last.read_attribute(primary_key).as(Int64)
    end
  end

  # Attaches a SQL comment to this query and returns the relation for chaining.
  #
  # The *comment* is emitted as an inline `/* ... */` comment in the generated
  # SQL (see `annotation_comment`), which is handy for tracing a query back to
  # the code that issued it in database logs or APM tools. Any `*/` in *comment*
  # is stripped so it cannot terminate the comment early.
  #
  # ```
  # User.where(active: true).annotate("dashboard#index").select
  # # => SELECT ... FROM users WHERE active = ? /* dashboard#index */
  # ```
  def annotate(comment : String) : self
    @query_annotation = comment
    self
  end

  # Returns the SQL comment fragment for this query's annotation, sanitized.
  #
  # The comment is wrapped in `/* ... */`. Any `*/` sequence in the supplied
  # comment is stripped so it cannot terminate the comment early and inject
  # trailing SQL. Returns `nil` when no annotation is set.
  def annotation_comment : String?
    if ann = @query_annotation
      safe = ann.gsub("*/", "")
      "/* #{safe} */"
    end
  end
end

# Class methods for bulk operations
module Grant::BulkOperations
  # Bulk insert records
  def insert_all(attributes : Array(Hash(String | Symbol, Grant::Columns::Type)),
                 returning : Array(Symbol)? = nil,
                 unique_by : Array(Symbol)? = nil,
                 record_timestamps : Bool = true) : Array(self)
    guard_writes!
    return [] of self if attributes.empty?

    # Transform all keys to strings and ensure proper types
    string_attributes = attributes.map do |attrs|
      attrs.transform_keys(&.to_s).transform_values { |v| v.as(Grant::Columns::Type) }
    end

    # Add timestamps if needed
    if record_timestamps
      now = Time.utc.as(Grant::Columns::Type)
      string_attributes = string_attributes.map do |attrs|
        new_attrs = attrs.dup
        new_attrs["created_at"] ||= now
        new_attrs["updated_at"] ||= now
        new_attrs
      end
    end

    # Create a query builder to get assembler
    builder = __builder
    assembler = builder.assembler
    sql = assembler.insert_all_sql(
      attributes: string_attributes,
      returning: returning,
      unique_by: unique_by
    )

    records = [] of self

    mark_write_operation
    adapter.open do |db|
      db.query(sql, args: assembler.numbered_parameters) do |rs|
        rs.each do
          record = self.new
          # Populate record from result set if returning was specified
          if returning
            returning.each do |field|
              value = read_column_value(rs, field.to_s)
              record.write_attribute(field.to_s, value)
            end
          end
          records << record
        end
      end
    end

    records
  end

  # Bulk upsert records
  def upsert_all(attributes : Array(Hash(String | Symbol, Grant::Columns::Type)),
                 returning : Array(Symbol)? = nil,
                 unique_by : Array(Symbol)? = nil,
                 update_only : Array(Symbol)? = nil,
                 record_timestamps : Bool = true) : Array(self)
    guard_writes!
    return [] of self if attributes.empty?

    # Transform all keys to strings and ensure proper types
    string_attributes = attributes.map do |attrs|
      attrs.transform_keys(&.to_s).transform_values { |v| v.as(Grant::Columns::Type) }
    end

    # Add timestamps if needed
    if record_timestamps
      now = Time.utc.as(Grant::Columns::Type)
      string_attributes = string_attributes.map do |attrs|
        new_attrs = attrs.dup
        new_attrs["created_at"] ||= now
        new_attrs["updated_at"] = now
        new_attrs
      end
    end

    # Create a query builder to get assembler
    builder = __builder
    assembler = builder.assembler
    sql = assembler.upsert_all_sql(
      attributes: string_attributes,
      returning: returning,
      unique_by: unique_by,
      update_only: update_only
    )

    records = [] of self

    mark_write_operation
    adapter.open do |db|
      db.query(sql, args: assembler.numbered_parameters) do |rs|
        rs.each do
          record = self.new
          # Populate record from result set if returning was specified
          if returning
            returning.each do |field|
              value = read_column_value(rs, field.to_s)
              record.write_attribute(field.to_s, value)
            end
          end
          records << record
        end
      end
    end

    records
  end

  private def read_column_value(rs, column_name : String)
    column = column_for_attribute(column_name)
    return nil unless column

    case column.column_type.name
    when "String"
      rs.read(String?)
    when "Int32"
      rs.read(Int32?)
    when "Int64"
      rs.read(Int64?)
    when "Float32"
      rs.read(Float32?)
    when "Float64"
      rs.read(Float64?)
    when "Bool"
      rs.read(Bool?)
    when "Time"
      rs.read(Time?)
    else
      rs.read(String?)
    end
  end
end

# Include in query builder
class Grant::Query::Builder(Model)
  include Grant::ConvenienceMethods(Model)

  @query_annotation : String?
  @_cached_assembler : Grant::Query::Assembler::Base(Model)?
end

# Include in Base
abstract class Grant::Base
  extend Grant::BulkOperations
end
