require "./sql/fragment"

module Grant::Bulk
  # How a bulk write treats a row that collides with a unique key. The adapter
  # turns it into `ON CONFLICT` (PostgreSQL, SQLite) or `ON DUPLICATE KEY`
  # (MySQL) text; see `Grant::Adapter::Base#bulk_insert_sql`.
  struct Conflict
    enum Mode
      # A duplicate fails the statement (`insert_all!`).
      Raise
      # A duplicate row is skipped (`insert_all`).
      Skip
      # A duplicate row updates the existing one (`upsert_all`).
      Update
    end

    getter mode : Mode
    # Columns named by the conflict target. Empty means any unique key.
    getter target : Array(String)
    # Columns copied from the incoming row on a duplicate.
    getter update_columns : Array(String)
    # Replaces the generated assignment list when present.
    getter update_sql : Grant::Sql::Fragment?
    # When set, an update applies only if the existing row holds the same value
    # in this column as the incoming row (the tenant column of a multitenant
    # model), so an upsert never rewrites another tenant's row.
    getter guard_column : String?

    def initialize(@mode : Mode, @target : Array(String) = [] of String,
                   @update_columns : Array(String) = [] of String,
                   @update_sql : Grant::Sql::Fragment? = nil,
                   @guard_column : String? = nil)
    end
  end
end

# Class methods for bulk writes. Rows go to the database in multi-row `INSERT`
# statements, with no validations, callbacks or per-row round trips; this is
# ActiveRecord's `insert_all` family.
module Grant::BulkOperations
  # Inserts *rows* in as few statements as the adapter's bind-parameter cap
  # allows, skipping rows that collide with a unique key.
  #
  # Returns lightweight records carrying the `RETURNING` columns (the primary
  # key unless *returning* names others) for the rows actually inserted. Pass
  # `returning: [] of Symbol` to skip that. MySQL has no `RETURNING`, so it
  # returns no records and raises when *returning* is given explicitly.
  #
  # *unique_by* is a list of column names, or the name of a unique index, to
  # scope the skip to one constraint. Every row must have the same keys.
  #
  # ```
  # User.insert_all([{"email" => "a@x.com"}, {"email" => "b@x.com"}])
  # ```
  def insert_all(rows : Array(Hash(K, V)),
                 returning : Array(Symbol)? = nil,
                 unique_by : (Array(Symbol) | String)? = nil,
                 record_timestamps : Bool? = nil) : Array(self) forall K, V
    __bulk_write(rows, Grant::Bulk::Conflict::Mode::Skip, returning, unique_by, nil, nil, record_timestamps)[0]
  end

  # Like `insert_all`, but a row that collides with a unique key raises
  # `Grant::RecordNotUnique` instead of being skipped.
  def insert_all!(rows : Array(Hash(K, V)),
                  returning : Array(Symbol)? = nil,
                  record_timestamps : Bool? = nil) : Array(self) forall K, V
    __bulk_write(rows, Grant::Bulk::Conflict::Mode::Raise, returning, nil, nil, nil, record_timestamps)[0]
  end

  # Inserts *rows*, updating the existing row when one collides with the unique
  # key (*unique_by*, default the primary key).
  #
  # By default every inserted column except the key, the primary key and
  # read-only columns is updated. *update_only* narrows that list;
  # *on_duplicate* replaces it with your own `SET` text, given as a
  # `Grant::Sql::Fragment` so it cannot be built from user input. The two are
  # exclusive. `updated_at` / `updated_on` are set to now when the model has them.
  #
  # ```
  # Product.upsert_all(rows, unique_by: [:sku], update_only: [:price])
  # Product.upsert_all(rows, unique_by: [:sku],
  #   on_duplicate: Grant::Sql.fragment("stock = stock + EXCLUDED.stock"))
  # ```
  def upsert_all(rows : Array(Hash(K, V)),
                 returning : Array(Symbol)? = nil,
                 unique_by : (Array(Symbol) | String)? = nil,
                 update_only : Array(Symbol)? = nil,
                 on_duplicate : Grant::Sql::Fragment? = nil,
                 record_timestamps : Bool? = nil) : Array(self) forall K, V
    __bulk_write(rows, Grant::Bulk::Conflict::Mode::Update, returning, unique_by, update_only, on_duplicate, record_timestamps)[0]
  end

  # Inserts one row, skipping it when it collides with a unique key. Returns the
  # inserted record, or nil when the row was skipped.
  def insert(row : Hash(K, V),
             returning : Array(Symbol)? = nil,
             unique_by : (Array(Symbol) | String)? = nil,
             record_timestamps : Bool? = nil) : self? forall K, V
    __bulk_single(row, Grant::Bulk::Conflict::Mode::Skip, returning, unique_by, nil, nil, record_timestamps)
  end

  # Inserts one row, raising `Grant::RecordNotUnique` when it collides with a
  # unique key.
  def insert!(row : Hash(K, V),
              returning : Array(Symbol)? = nil,
              record_timestamps : Bool? = nil) : self forall K, V
    __bulk_single(row, Grant::Bulk::Conflict::Mode::Raise, returning, nil, nil, nil, record_timestamps) ||
      raise Grant::StatementInvalid.new("insert! wrote no row into #{table_name}")
  end

  # Inserts one row, or updates the existing row that collides with *unique_by*.
  # Takes the options of `upsert_all`. Returns the written record.
  def upsert(row : Hash(K, V),
             returning : Array(Symbol)? = nil,
             unique_by : (Array(Symbol) | String)? = nil,
             update_only : Array(Symbol)? = nil,
             on_duplicate : Grant::Sql::Fragment? = nil,
             record_timestamps : Bool? = nil) : self? forall K, V
    __bulk_single(row, Grant::Bulk::Conflict::Mode::Update, returning, unique_by, update_only, on_duplicate, record_timestamps)
  end

  # Runs one column value through the model's declared converter, and widens
  # plain numbers to the column's declared width. Values already at the
  # database level pass through unchanged.
  #
  # :nodoc:
  def __bulk_cast(column : String, value) : Grant::Columns::Type
    {% begin %}
      case column
      {% for ivar in @type.instance_vars.select(&.annotation(Grant::Column)) %}
        {% ann = ivar.annotation(Grant::Column) %}
        {% app_type = ivar.type.union_types.reject { |type| type == Nil }.first %}
      when {{ ivar.name.stringify }}
        {% if ann[:converter] %}
          if value.is_a?({{ app_type }})
            return {{ ann[:converter] }}.to_db(value)
          end
        {% elsif app_type == Int32 %}
          return value.to_i32 if value.is_a?(Int)
        {% elsif app_type == Int64 %}
          return value.to_i64 if value.is_a?(Int)
        {% elsif app_type == Float32 %}
          return value.to_f32 if value.is_a?(Number)
        {% elsif app_type == Float64 %}
          return value.to_f64 if value.is_a?(Number)
        {% end %}
      {% end %}
      end
    {% end %}
    return if value.nil?
    return value if value.is_a?(Grant::Columns::Type)
    raise ArgumentError.new("Cannot store #{value.class} in #{name}.#{column}; declare a converter for the column")
  end

  private def __bulk_single(row : Hash(K, V), mode : Grant::Bulk::Conflict::Mode,
                            returning : Array(Symbol)?, unique_by : (Array(Symbol) | String)?,
                            update_only : Array(Symbol)?, on_duplicate : Grant::Sql::Fragment?,
                            record_timestamps : Bool?) : self? forall K, V
    records, affected, last_id = __bulk_write([row], mode, returning, unique_by, update_only, on_duplicate, record_timestamps)
    if record = records.first?
      return record
    end
    return if affected == 0 || (returning && !returning.empty?)

    # No RETURNING (MySQL, SQLite before 3.35): rebuild the key from the write.
    key = primary_name
    record = new
    if given = row.find { |name, _| name.to_s == key }
      record.write_attribute(key, __bulk_cast(key, given[1]))
    elsif last_id > 0
      record.write_attribute(key, __bulk_cast(key, last_id))
    end
    record
  end

  # Builds and runs the statements. Returns the returned records, the rows
  # affected, and the last generated id.
  private def __bulk_write(rows : Array(Hash(K, V)), mode : Grant::Bulk::Conflict::Mode,
                           returning : Array(Symbol)?, unique_by : (Array(Symbol) | String)?,
                           update_only : Array(Symbol)?, on_duplicate : Grant::Sql::Fragment?,
                           record_timestamps : Bool?) : Tuple(Array(self), Int64, Int64) forall K, V
    guard_writes!
    if update_only && on_duplicate
      raise ArgumentError.new("Pass either update_only or on_duplicate, not both")
    end

    known = fields
    keys = rows.first?.try(&.keys.map(&.to_s).sort!) || [] of String
    rows.each do |row|
      if row.keys.map(&.to_s).sort! != keys
        raise ArgumentError.new("All objects being inserted must have the same keys")
      end
    end
    keys.each do |key|
      raise ArgumentError.new("Unknown column #{key.inspect} for #{name}") unless known.includes?(key)
    end

    values = rows.map do |row|
      converted = Hash(String | Symbol, Grant::Columns::Type).new
      row.each { |key, value| converted[key.to_s] = __bulk_cast(key.to_s, value) }
      converted
    end
    values = __apply_tenant_to_bulk_attributes(values)
    return {[] of self, 0_i64, 0_i64} if values.empty?

    # `nil` follows the model's `record_timestamps` setting, as in ActiveRecord.
    stamp = record_timestamps.nil? ? record_timestamps? : record_timestamps
    auto_created = [] of String
    if stamp
      now = Grant::Timestamps.current_time.as(Grant::Columns::Type)
      timestamped_attributes.each do |column_name|
        if Grant::Timestamps::CREATED_COLUMNS.includes?(column_name)
          if values.any? { |row| !row.has_key?(column_name) || row[column_name].nil? }
            auto_created << column_name
          end
          values.each { |row| row[column_name] ||= now }
        elsif mode.update?
          values.each { |row| row[column_name] = now }
        else
          values.each { |row| row[column_name] ||= now }
        end
      end
    end

    columns = values.first.keys.map(&.to_s)
    conflict = __bulk_conflict(mode, columns, unique_by, update_only, on_duplicate, stamp, auto_created)

    returning_columns = __bulk_returning(returning)
    mark_write_operation

    per_chunk = adapter.bulk_chunk_rows(columns.size)
    records = [] of self
    affected = 0_i64
    last_id = 0_i64
    run = -> {
      values.each_slice(per_chunk) do |chunk|
        binds = [] of Grant::Columns::Type
        chunk.each { |row| columns.each { |column| binds << row[column] } }
        sql = Grant::QueryLogs.append(adapter.bulk_insert_sql(table_name, columns, chunk.size, conflict, returning_columns))
        elapsed = Time.measure do
          adapter.open(sql, binds, name) do |db|
            if returning_columns
              db.query(sql, args: adapter.normalize_bind_values(binds)) do |rs|
                rs.each { records << __bulk_returned_record(rs, returning_columns) }
              end
            else
              result = db.exec(sql, args: adapter.normalize_bind_values(binds))
              affected += result.rows_affected
              last_id = result.last_insert_id
            end
          end
        end
        adapter.log sql, elapsed, binds
      end
    }

    # Chunks of one call succeed or fail together.
    if values.size > per_chunk
      transaction { run.call }
    else
      run.call
    end

    {records, affected, last_id}
  end

  private def __bulk_conflict(mode : Grant::Bulk::Conflict::Mode, columns : Array(String),
                              unique_by : (Array(Symbol) | String)?, update_only : Array(Symbol)?,
                              on_duplicate : Grant::Sql::Fragment?, record_timestamps : Bool,
                              auto_created : Array(String)) : Grant::Bulk::Conflict
    return Grant::Bulk::Conflict.new(mode) if mode.raise?

    target = [] of String
    if unique_by.is_a?(String)
      target = adapter.unique_index_columns(table_name, unique_by) ||
               raise ArgumentError.new("No unique index named #{unique_by.inspect} on #{table_name}")
    elsif unique_by.is_a?(Array(Symbol))
      target = unique_by.map(&.to_s)
      target.each do |column|
        raise ArgumentError.new("Unknown unique_by column #{column.inspect} for #{name}") unless fields.includes?(column)
      end
    end
    return Grant::Bulk::Conflict.new(mode, target) if mode.skip?

    target = [primary_name] if target.empty? && !adapter.mysql?
    guard = __bulk_tenant_guard_column
    return Grant::Bulk::Conflict.new(mode, target, update_sql: on_duplicate, guard_column: guard) if on_duplicate

    update_columns = if update_only
                       update_only.map(&.to_s).tap do |list|
                         list.each do |column|
                           raise ArgumentError.new("update_only column #{column.inspect} is not part of the inserted rows") unless columns.includes?(column)
                         end
                         if record_timestamps
                           update_timestamp_columns.each do |column|
                             list << column if columns.includes?(column) && !list.includes?(column)
                           end
                         end
                       end
                     else
                       skipped = target + [primary_name] + readonly_attributes
                       skipped.concat(auto_created)
                       columns.reject { |column| skipped.includes?(column) }
                     end
    Grant::Bulk::Conflict.new(mode, target, update_columns, guard_column: guard)
  end

  # nil means "no RETURNING clause".
  private def __bulk_returning(returning : Array(Symbol)?) : Array(String)?
    unless adapter.supports_insert_returning?
      if returning && !returning.empty?
        raise ArgumentError.new("#{adapter.class} does not support RETURNING on INSERT; omit returning:")
      end
      return
    end
    return if returning && returning.empty?

    columns = returning ? returning.map(&.to_s) : [primary_name]
    columns.each do |column|
      raise ArgumentError.new("Unknown returning column #{column.inspect} for #{name}") unless fields.includes?(column)
    end
    columns
  end

  private def __bulk_returned_record(rs : DB::ResultSet, columns : Array(String)) : self
    record = new
    columns.each do |column|
      record.write_attribute(column, __bulk_read_column(rs, column))
    end
    record
  end

  private def __bulk_read_column(rs : DB::ResultSet, column_name : String) : Grant::Columns::Type
    {% begin %}
      case column_name
      {% for ivar in @type.instance_vars.select(&.annotation(Grant::Column)) %}
        {% app_type = ivar.type.union_types.reject { |type| type == Nil }.first %}
      when {{ ivar.name.stringify }}
        {% if app_type == Int32 %}
          rs.read(Int32?)
        {% elsif app_type == Int64 %}
          rs.read(Int64?)
        {% elsif app_type == Float32 %}
          rs.read(Float32?)
        {% elsif app_type == Float64 %}
          rs.read(Float64?)
        {% elsif app_type == Bool %}
          rs.read(Bool?)
        {% elsif app_type == Time %}
          adapter.read_nullable_time(rs)
        {% elsif app_type == UUID %}
          if adapter.postgres?
            rs.read(UUID?)
          else
            text = rs.read(String?)
            text ? UUID.new(text) : nil
          end
        {% else %}
          rs.read(String?)
        {% end %}
      {% end %}
      else
        raise ArgumentError.new("Unknown returning column #{column_name.inspect} for #{name}")
      end
    {% end %}
  end
end

abstract class Grant::Base
  extend Grant::BulkOperations
end
