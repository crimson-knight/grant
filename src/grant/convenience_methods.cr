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
  def pluck(*fields : Symbol | String) : Array(Array(Grant::Columns::Type))
    return [] of Array(Grant::Columns::Type) if is_none?

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
  def pick(*fields : Symbol | String) : Array(Grant::Columns::Type)?
    limit(1).pluck(*fields).first?
  end

  # Returns a copy of this relation carrying a SQL comment.
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
    copy = chain_copy
    copy.set_query_annotation(comment)
    copy
  end

  # :nodoc:
  protected def set_query_annotation(comment : String) : Nil
    reset_load_state
    @query_annotation = comment
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
    builder = __builder

    # Transform all keys to strings and ensure proper types
    string_attributes = attributes.map do |attrs|
      attrs.transform_keys(&.to_s).transform_values { |v| v.as(Grant::Columns::Type) }
    end

    string_attributes = __apply_tenant_to_bulk_attributes(string_attributes)
    return [] of self if string_attributes.empty?

    # Add timestamps if needed
    if record_timestamps
      now = Time.utc.as(Grant::Columns::Type)
      timestamp_columns = self.fields
      string_attributes = string_attributes.map do |attrs|
        new_attrs = attrs.dup
        new_attrs["created_at"] ||= now if timestamp_columns.includes?("created_at")
        new_attrs["updated_at"] ||= now if timestamp_columns.includes?("updated_at")
        new_attrs
      end
    end

    # Create a query builder to get assembler
    assembler = builder.assembler
    sql = assembler.insert_all_sql(
      attributes: string_attributes,
      returning: returning,
      unique_by: unique_by
    )

    records = [] of self

    mark_write_operation
    adapter.open do |db|
      if adapter.mysql?
        raise ArgumentError.new("MySQL does not support insert_all returning columns") if returning
        db.exec(sql, args: adapter.normalize_bind_values(assembler.numbered_parameters))
      else
        db.query(sql, args: adapter.normalize_bind_values(assembler.numbered_parameters)) do |rs|
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
    builder = __builder

    # Transform all keys to strings and ensure proper types
    string_attributes = attributes.map do |attrs|
      attrs.transform_keys(&.to_s).transform_values { |v| v.as(Grant::Columns::Type) }
    end

    string_attributes = __apply_tenant_to_bulk_attributes(string_attributes)
    return [] of self if string_attributes.empty?

    # Add timestamps if needed
    if record_timestamps
      now = Time.utc.as(Grant::Columns::Type)
      timestamp_columns = self.fields
      string_attributes = string_attributes.map do |attrs|
        new_attrs = attrs.dup
        new_attrs["created_at"] ||= now if timestamp_columns.includes?("created_at")
        new_attrs["updated_at"] = now if timestamp_columns.includes?("updated_at")
        new_attrs
      end
    end

    # Create a query builder to get assembler
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
      if adapter.mysql?
        raise ArgumentError.new("MySQL does not support upsert_all returning columns") if returning
        db.exec(sql, args: adapter.normalize_bind_values(assembler.numbered_parameters))
      else
        db.query(sql, args: adapter.normalize_bind_values(assembler.numbered_parameters)) do |rs|
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
