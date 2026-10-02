require "./timestamps"

# Atomic counter updates. `col = COALESCE(col, 0) + n` runs in the database, so
# concurrent writers never lose an increment, and an id list is a single
# `WHERE pk IN (...)` statement.
#
# ```
# Post.update_counters(1, {:views_count => 1, :likes_count => -1})
# Post.update_counters([1, 2, 3], {:views_count => 1}, touch: true)
# ```
module Grant::Counters
  MAX_IDS_PER_STATEMENT = 10_000

  module ClassMethods
    # Adjusts counter columns on the row with primary key *id*. See the array
    # overload for *counters* and *touch*. Returns the number of rows changed.
    def update_counters(id : Grant::Querying::IdValue, counters : Hash(K, T), touch : Bool | Symbol | Array(Symbol) = false) : Int64 forall K, T
      guard_writes!
      __apply_counter_update(current_scope.where(primary_name, :eq, id.as(Grant::Columns::Type)), counters, touch)
    end

    # Adjusts counter columns on every row whose primary key is in *ids* with one
    # `UPDATE ... WHERE pk IN (...)` statement.
    #
    # *counters* maps a column to a signed delta (positive adds, negative
    # subtracts; a NULL column counts as zero). Unlike earlier versions this
    # does not bump `updated_at` unless asked, matching ActiveRecord: pass
    # `touch: true` to refresh the model's update timestamp columns in the same
    # statement, or a column name (or names) to refresh those as well.
    #
    # ```
    # User.update_counters(user.id!, {:login_count => 1, :failures => -1})
    # User.update_counters([1, 2], {:login_count => 1}, touch: :last_seen_at)
    # ```
    def update_counters(ids : Array(I), counters : Hash(K, T), touch : Bool | Symbol | Array(Symbol) = false) : Int64 forall I, K, T
      guard_writes!
      return 0_i64 if ids.empty?

      # One statement per slice keeps very long lists under the bind-parameter
      # limit of every adapter; ordinary lists are a single statement.
      affected = 0_i64
      ids.each_slice(MAX_IDS_PER_STATEMENT) do |slice|
        affected += __apply_counter_update(current_scope.where(primary_name, :in, slice), counters, touch)
      end
      affected
    end

    # Runs the counter `UPDATE` against the rows *query* selects. Shared by
    # `update_counters` and the record-level `increment!` / `decrement!`, which
    # scope *query* to a single primary key.
    #
    # :nodoc:
    def __apply_counter_update(query, counters : Hash(K, T), touch : Bool | Symbol | Array(Symbol) = false, time : Time = Grant::Timestamps.current_time) : Int64 forall K, T
      return 0_i64 if counters.empty?

      assembler = query.assembler
      where_clause = assembler.where || raise Grant::Querying::MissingWhereClauseError.new("Counter update has no WHERE clause")
      where_parameters = assembler.numbered_parameters

      set_clause = [] of String
      set_values = [] of Grant::Columns::Type
      placeholder_index = where_parameters.size

      counters.each do |column, delta|
        column_name = quote(column.to_s)
        placeholder_index += 1
        placeholder = adapter.parameter_placeholder(placeholder_index)
        operator = delta < 0 ? "-" : "+"
        set_clause << "#{column_name} = COALESCE(#{column_name}, 0) #{operator} #{placeholder}"
        set_values << delta.abs.as(Grant::Columns::Type)
      end

      __counter_touch_columns(touch).each do |column|
        placeholder_index += 1
        set_clause << "#{quote(column)} = #{adapter.parameter_placeholder(placeholder_index)}"
        set_values << time
      end

      sql = Grant::QueryLogs.append("UPDATE #{quoted_table_name} SET #{set_clause.join(", ")} #{where_clause}")
      values = if adapter.postgres?
                 where_parameters + set_values
               else
                 set_values + where_parameters
               end

      mark_write_operation
      affected = 0_i64
      elapsed_time = Time.measure do
        # Pass the statement so a driver failure is translated with its SQL, and
        # let the adapter count the rows (SQLite reads `changes()`).
        adapter.open(sql, values, name) do |db|
          result = db.exec(sql, args: adapter.normalize_bind_values(values))
          affected = adapter.rows_affected_after_write(db, result)
        end
      end
      adapter.log(sql, elapsed_time, values)
      affected
    end

    # The timestamp columns a counter update refreshes for a `touch:` argument.
    # Named columns must be declared `Time` columns.
    #
    # :nodoc:
    def __counter_touch_columns(touch : Bool | Symbol | Array(Symbol)) : Array(String)
      columns = [] of String
      case touch
      when false
        return columns
      when true
        # Only the update timestamps.
      when Symbol
        columns << touch.to_s
      when Array
        touch.each { |name| columns << name.to_s }
      end
      columns.each do |name|
        raise ArgumentError.new("#{self.name} has no column named #{name}") unless fields.includes?(name)
      end
      update_timestamp_columns.each { |name| columns << name unless columns.includes?(name) }
      columns
    end
  end
end
