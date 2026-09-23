module Grant::Querying
  alias IdValue = Int32 | Int64 | Float32 | Float64 | String

  class NotFound < Exception
  end

  class NotUnique < Exception
  end

  class ScopedRawSqlError < Exception
  end

  module ClassMethods
    # Builds a single model instance from the current row of a result set.
    #
    # Marks the record as persisted (not a new record) and fires the
    # `after_find` callback if the model defines one. This is the low-level
    # entry point used by every read path; you rarely call it directly.
    #
    # *result* is a positioned `DB::ResultSet` (its cursor must already point at
    # a row). Returns the hydrated model instance.
    #
    # ```
    # class User < Grant::Base
    #   column id : Int64, primary: true
    #   column email : String
    #   column active : Bool
    # end
    #
    # User.adapter.open do |db|
    #   db.query("SELECT * FROM users LIMIT 1") do |rs|
    #     rs.each { user = User.from_rs(rs) }
    #   end
    # end
    # ```
    def from_rs(result : DB::ResultSet) : self
      model = new
      model.new_record = false
      model.from_rs result
      model.after_find if model.responds_to?(:after_find)
      model
    end

    # Runs a raw SQL fragment against the model's table and hydrates the rows.
    #
    # Runs *clause* after the generated `SELECT ... FROM table`. When the model
    # has a default scope, that scope is applied inside a subquery before the
    # clause runs. Use it for JOINs or multi-parameter clauses the chainable
    # builder can't express; use `unscoped` for a deliberate scope bypass.
    #
    # - *clause*: SQL appended after the SELECT list (e.g. `"WHERE email = ?"`,
    #   or a full `"JOIN ... WHERE ..."`). Defaults to `""` (all rows).
    # - *params*: positional bind values substituted for `?` placeholders.
    #
    # Returns an `Array(self)` of hydrated records (eagerly loaded).
    #
    # ```
    # User.raw_all("WHERE active = ?", [true])
    # User.raw_all("WHERE email LIKE ? ORDER BY id DESC", ["%@example.com"])
    # ```
    def raw_all(clause = "", params = [] of Grant::Columns::Type) : Array(self)
      rows = [] of self
      if responds_to?(:current_scope)
        scoped_query = current_scope
        scoped_assembler = scoped_query.assembler
        scoped_sql = scoped_assembler.select.raw_sql
        scoped_params = scoped_assembler.numbered_parameters.dup
        scoped_params.concat(params)

        clean_clause = clause.strip
        unless clean_clause.empty?
          alias_name = adapter.quote(table_name)
          selected_fields = (scoped_query.select_columns || fields).map do |field|
            "#{alias_name}.#{adapter.quote(field)}"
          end.join(", ")
          clean_clause = adapter.ensure_clause_template(clean_clause, scoped_params.size - params.size)
          scoped_sql = "SELECT #{selected_fields} FROM (#{scoped_sql}) AS #{alias_name} #{clean_clause}"
        end

        adapter.select(Grant::Select::Container.new(scoped_sql), "", scoped_params) do |results|
          results.each do
            rows << from_rs(results)
          end
        end
      else
        adapter.select(select_container, clause, params) do |results|
          results.each do
            rows << from_rs(results)
          end
        end
      end
      rows
    end

    # Returns all rows of the model's table, optionally filtered by a raw SQL *clause*.
    #
    # The *clause* accepts any SQL92-compatible fragment (WHERE, JOIN, GROUP BY,
    # ORDER BY, etc.) appended after the generated SELECT, so you are never
    # restricted to a DSL. Results are lazy: no query runs until you iterate or
    # call a terminal method on the returned collection.
    #
    # For most filtering prefer the chainable builder (`Model.where(...)`); reach
    # for `all` with a raw clause when you need SQL the builder can't express.
    #
    # - *clause*: SQL appended after `SELECT ... FROM table` (default `""` = every row).
    # - *params*: positional bind values for `?` placeholders in *clause*.
    # - *use_primary_adapter*: when `true` (default) the read is routed to the
    #   primary connection (so it sees prior writes); set `false` to allow a
    #   read replica.
    #
    # Returns a lazily-evaluated collection that yields `self` instances.
    #
    # ```
    # User.all                             # every user (lazy)
    # User.all.to_a                        # force-load into an Array(User)
    # User.all("WHERE active = ?", [true]) # raw filtered query
    # User.all.each { |user| puts user.email }
    # ```
    def all(clause = "", params = [] of Grant::Columns::Type, use_primary_adapter = true)
      mark_write_operation if use_primary_adapter == true

      # If we have scoping support, use current_scope
      if responds_to?(:current_scope)
        clean_clause = clause.strip
        # Fall back to raw_all for clauses that the query builder can't handle:
        # - JOIN clauses (e.g. from :through associations)
        # - Multiple parameters (query.where only accepts a single value)
        if clean_clause.includes?("JOIN ") || params.size > 1 || clean_clause.upcase.starts_with?("ORDER BY ")
          Collection(self).new(-> { raw_all(clause, params) })
        else
          query = current_scope
          if !clean_clause.empty?
            # Handle WHERE clause - strip the WHERE prefix if present
            if clean_clause.starts_with?("WHERE ")
              clean_clause = clean_clause[6..-1] # Remove "WHERE " prefix
            end
            if params.empty?
              query.where(clean_clause)
            else
              query.where(clean_clause, params.first)
            end
          end
          query.select
        end
      else
        Collection(self).new(-> { raw_all(clause, params) })
      end
    end

    # Returns the first matching record, or `nil` if none match.
    #
    # Adds a `LIMIT 1` to the query. Without a *clause* it returns the first row
    # by the table's natural/scoped order; add an `ORDER BY` clause for a
    # deterministic "first".
    #
    # - *clause*: optional raw SQL fragment (e.g. `"WHERE active = ?"`,
    #   `"ORDER BY id DESC"`).
    # - *params*: positional bind values for `?` placeholders in *clause*.
    #
    # ```
    # User.first                             # => #<User ...> or nil
    # User.first("WHERE active = ?", [true]) # first active user
    # User.first("ORDER BY id DESC")         # highest id
    # ```
    def first(clause = "", params = [] of Grant::Columns::Type)
      # If we have scoping support, use current_scope with limit
      if responds_to?(:current_scope)
        clean_clause = clause.strip
        # Fall back to raw_all for clauses that the query builder can't handle:
        # - JOIN clauses (e.g. from :through associations)
        # - Multiple parameters (query.where only accepts a single value)
        if clean_clause.includes?("JOIN ") || params.size > 1 || clean_clause.upcase.starts_with?("ORDER BY ")
          all([clean_clause, "LIMIT 1"].join(" "), params, false).first?
        else
          query = current_scope
          if !clean_clause.empty?
            # Handle WHERE clause - strip the WHERE prefix if present
            if clean_clause.starts_with?("WHERE ")
              clean_clause = clean_clause[6..-1] # Remove "WHERE " prefix
            end
            if params.empty?
              query.where(clean_clause)
            else
              query.where(clean_clause, params.first)
            end
          end
          if query.order_fields.empty?
            query.order_fields << {field: primary_name, direction: Grant::Query::Builder::Sort::Ascending}
          end
          query.limit(1).select.first?
        end
      else
        all([clause.strip, "LIMIT 1"].join(" "), params, false).first?
      end
    end

    # Like `first` but raises `NotFound` instead of returning `nil`.
    #
    # ```
    # User.first!                             # => #<User ...> (raises if table empty)
    # User.first!("WHERE active = ?", [true]) # => first active user or raises
    # ```
    def first!(clause = "", params = [] of Grant::Columns::Type)
      first(clause, params) || raise NotFound.new("No #{{{@type.name.stringify}}} found with first(#{clause})")
    end

    # Returns the record whose primary key equals *value*, or `nil` if none.
    #
    # *value* is the primary-key value to look up (e.g. an `Int64` id).
    #
    # ```
    # User.find(1)   # => #<User id: 1, ...> or nil
    # User.find(999) # => nil
    # ```
    def find(value)
      first("WHERE #{primary_name} = ?", [value])
    end

    # Like `find` but raises `NotFound` when no record has primary key *value*.
    #
    # ```
    # User.find!(1)   # => #<User id: 1, ...>
    # User.find!(999) # raises Grant::Querying::NotFound
    # ```
    def find!(value)
      find(value) || raise Grant::Querying::NotFound.new("No #{{{@type.name.stringify}}} found where #{primary_name} = #{value}")
    end

    # Returns the first record matching every column in *criteria*, or `nil`.
    #
    # Pass column/value pairs as keyword arguments; they are combined with AND.
    # A `nil` value matches `IS NULL`.
    #
    # ```
    # User.find_by(email: "a@example.com") # => #<User ...> or nil
    # User.find_by(active: true, email: "a@b.com")
    # ```
    def find_by(**criteria : Grant::Columns::Type)
      find_by criteria.to_h
    end

    # :ditto:
    #
    # Hash form — accepts a pre-built criteria hash (`Grant::ModelArgs`).
    #
    # ```
    # User.find_by({"email" => "a@example.com", "active" => true})
    # ```
    def find_by(criteria : Grant::ModelArgs)
      if criteria.keys.any? { |field| Grant::Encryption::EncryptedAttributeRegistry.for(name).has_key?(field.to_s) }
        return current_scope.where(criteria).first
      end

      clause, params = build_find_by_clause(criteria)
      first "WHERE #{clause}", params
    end

    # Like `find_by` but raises `NotFound` when nothing matches *criteria*.
    #
    # ```
    # User.find_by!(email: "a@example.com") # => #<User ...> or raises
    # ```
    def find_by!(**criteria : Grant::Columns::Type)
      find_by!(criteria.to_h)
    end

    # :ditto:
    #
    # Hash form — accepts a pre-built criteria hash (`Grant::ModelArgs`).
    def find_by!(criteria : Grant::ModelArgs)
      find_by(criteria) || raise NotFound.new("No #{{{@type.name.stringify}}} found where #{criteria.map { |k, v| %(#{k} #{v.nil? ? "is NULL" : "= #{v}"}) }.join(" and ")}")
    end

    # Returns the single record that matches the criteria. Raises `NotFound` if no record found.
    # Raises `NotUnique` if more than one record found.
    def sole(clause = "", params = [] of Grant::Columns::Type)
      # If we have scoping support, use current_scope
      if responds_to?(:current_scope)
        clean_clause = clause.strip
        # Fall back to raw_all for clauses that the query builder can't handle
        if clean_clause.includes?("JOIN ") || params.size > 1 || clean_clause.upcase.starts_with?("ORDER BY ")
          results = all(clause, params, false).to_a
        else
          query = current_scope
          if !clean_clause.empty?
            # Handle WHERE clause - strip the WHERE prefix if present
            if clean_clause.starts_with?("WHERE ")
              clean_clause = clean_clause[6..-1] # Remove "WHERE " prefix
            end
            if params.empty?
              query.where(clean_clause)
            else
              query.where(clean_clause, params.first)
            end
          end
          results = query.select.to_a
        end
      else
        results = all(clause, params, false).to_a
      end

      case results.size
      when 0
        raise NotFound.new("No #{{{@type.name.stringify}}} found")
      when 1
        results.first
      else
        raise NotUnique.new("Multiple #{{{@type.name.stringify}}} records found (expected exactly one)")
      end
    end

    # Returns the single record that matches the given criteria. Raises `NotFound` if no record found.
    # Raises `NotUnique` if more than one record found.
    def find_sole_by(**criteria : Grant::Columns::Type)
      find_sole_by(criteria.to_h)
    end

    # :ditto:
    def find_sole_by(criteria : Grant::ModelArgs)
      if criteria.empty?
        sole
      else
        clause, params = build_find_by_clause(criteria)
        sole("WHERE #{clause}", params)
      end
    end

    # Finds and destroys all records matching the given criteria
    def destroy_by(**criteria : Grant::Columns::Type) : Int32
      destroy_by(criteria.to_h)
    end

    # :ditto:
    def destroy_by(criteria : Grant::ModelArgs) : Int32
      guard_writes!
      query = current_scope
      query = query.where(criteria) unless criteria.empty?
      records = query.select

      count = 0
      records.each do |record|
        if record.destroy
          count += 1
        end
      end
      count
    end

    # Finds and deletes all records matching the given criteria (skips callbacks)
    def delete_by(**criteria : Grant::Columns::Type) : Int64
      delete_by(criteria.to_h)
    end

    # :ditto:
    def delete_by(criteria : Grant::ModelArgs) : Int64
      guard_writes!
      mark_write_operation
      query = current_scope
      query = query.where(criteria) unless criteria.empty?
      query.delete_all
    end

    # Updates updated_at timestamp for all records matching the given criteria
    def touch_all(*fields, time : Time = Time.local(Grant.settings.default_timezone)) : Int64
      guard_writes!
      current_scope.touch_all(*fields, time: time)
    end

    # Updates counter columns for all records
    def update_counters(id : IdValue, counters : Hash(Symbol, Int32)) : Int64
      guard_writes!
      query = current_scope.where(primary_name, :eq, id)
      assembler = query.assembler
      where_clause = assembler.where
      where_parameters = assembler.numbered_parameters
      set_clause = [] of String
      set_values = [] of Grant::Columns::Type
      placeholder_index = where_parameters.size

      counters.each do |column, value|
        column_name = quote(column.to_s)
        placeholder_index += 1
        placeholder = adapter.parameter_placeholder(placeholder_index)
        if value > 0
          set_clause << "#{column_name} = #{column_name} + #{placeholder}"
        else
          set_clause << "#{column_name} = #{column_name} - #{placeholder}"
        end
        set_values << value.abs
      end

      # Also update the updated_at timestamp
      {% if @type.instance_vars.select { |ivar| ivar.annotation(Grant::Column) && ivar.name == "updated_at" }.size > 0 %}
        placeholder_index += 1
        placeholder = adapter.parameter_placeholder(placeholder_index)
        set_clause << "#{quote("updated_at")} = #{placeholder}"
        set_values << Time.local(Grant.settings.default_timezone).at_beginning_of_second
      {% end %}

      return 0_i64 if set_clause.empty?

      sql = "UPDATE #{quoted_table_name} SET #{set_clause.join(", ")} #{where_clause}"
      values = if adapter.class.to_s == "Grant::Adapter::Pg"
                 where_parameters + set_values
               else
                 set_values + where_parameters
               end

      mark_write_operation
      adapter.open do |db|
        db.exec(sql, args: values).rows_affected
      end
    end

    # Iterates over every matching record one at a time, loading them in batches.
    #
    # Memory-friendly for large tables: instead of loading the whole result set,
    # it pages through it with LIMIT/OFFSET and yields each record individually.
    # Built on `find_in_batches`.
    #
    # - *clause* / *params*: optional raw SQL filter (as in `all`).
    # - *batch_size*: rows fetched per page (default `100`).
    # - *offset*: starting row offset (default `0`).
    #
    # ```
    # User.find_each(batch_size: 500) do |user|
    #   puts user.email
    # end
    #
    # User.find_each("WHERE active = ?", [true]) do |user|
    #   process(user)
    # end
    # ```
    def find_each(clause = "", params = [] of Grant::Columns::Type, batch_size limit = 100, offset = 0, &)
      find_in_batches(clause, params, batch_size: limit, offset: offset) do |batch|
        batch.each do |record|
          yield record
        end
      end
    end

    # Iterates over matching records in batches, yielding each batch as an Array.
    #
    # Pages through the result set with LIMIT/OFFSET so a large table is never
    # fully materialized at once. Use this (rather than `find_each`) when you can
    # process records a batch at a time (e.g. bulk updates).
    #
    # - *clause* / *params*: optional raw SQL filter (as in `all`).
    # - *batch_size*: rows per batch (default `100`). Must be `>= 1`.
    # - *offset*: starting row offset (default `0`).
    #
    # Raises `ArgumentError` if *batch_size* is less than 1.
    #
    # ```
    # User.find_in_batches(batch_size: 1000) do |batch|
    #   puts "processing #{batch.size} users"
    # end
    # ```
    def find_in_batches(clause = "", params = [] of Grant::Columns::Type, batch_size limit = 100, offset = 0, &)
      if limit < 1
        raise ArgumentError.new("batch_size must be >= 1")
      end

      loop do
        ordered_clause = clause.strip
        unless ordered_clause.upcase.includes?("ORDER BY")
          order_clause = "ORDER BY #{quote(primary_name)} ASC"
          ordered_clause = [ordered_clause, order_clause].reject(&.empty?).join(" ")
        end
        results = all "#{ordered_clause} LIMIT ? OFFSET ?", params + [limit, offset], false
        break if results.empty?
        yield results
        offset += limit
      end
    end

    # Returns `true` if a record exists with primary key *id*, otherwise `false`.
    #
    # A `nil` *id* always returns `false`. This runs an efficient existence
    # check (no rows are hydrated).
    #
    # ```
    # User.exists?(1)   # => true
    # User.exists?(999) # => false
    # User.exists?(nil) # => false
    # ```
    def exists?(id : IdValue | Nil) : Bool
      query = current_scope
      return false if id.nil?
      query.where(primary_name.not_nil!, :eq, id).exists?
    end

    # Returns `true` if any record matches *criteria*, otherwise `false`.
    #
    # Pass column/value pairs as keyword arguments; they are combined with AND.
    #
    # ```
    # User.exists?(email: "a@example.com") # => true/false
    # User.exists?(active: true, id: 1)
    # ```
    def exists?(**criteria : Grant::Columns::Type) : Bool
      exists? criteria.to_h
    end

    # :ditto:
    #
    # Hash form — accepts a pre-built criteria hash (`Grant::ModelArgs`).
    def exists?(criteria : Grant::ModelArgs) : Bool
      current_scope.where(criteria).exists?
    end

    # Returns the number of rows in the model's current scope.
    #
    # Counts the default scope and any active filters. To count an additional
    # filtered set, use the chainable builder: `User.where(active: true).count`.
    #
    # ```
    # User.count # => 42 (within the default scope, when present)
    # ```
    def count : Int32
      result = current_scope.count
      total = case result
              when Int64
                result
              when Hash(Grant::Columns::Type, Int64)
                result.values.sum
              else
                result.values.sum
              end
      total.to_i32
    end

    def exec(clause = "")
      guard_writes!
      ensure_raw_sql_unscoped!
      mark_write_operation
      adapter.open(&.exec(clause))
    end

    def query(clause = "", params = [] of Grant::Columns::Type, &)
      guard_writes!
      ensure_raw_sql_unscoped!
      mark_write_operation
      clause = adapter.ensure_clause_template(clause)
      adapter.open { |db| db.query(clause, args: params) { |rs| yield rs } }
    end

    def scalar(clause = "", &)
      ensure_raw_sql_unscoped!
      mark_write_operation
      adapter.open { |db| yield db.scalar(clause) }
    end

    private def ensure_raw_sql_unscoped!
      if self.responds_to?(:_has_default_scope?) && self._has_default_scope? && !self._unscoped?
        Grant::Tenant.current! if self.responds_to?(:multitenant_column)
        raise Grant::Querying::ScopedRawSqlError.new(
          "Raw SQL cannot apply the default scope for #{self.name}. " \
          "Wrap deliberate raw access in #{self.name}.unscoped { ... }.")
      end
    end

    private def exec_exists(clause : String, params : Array(Grant::Columns::Type)) : Bool
      self.adapter.exists? quoted_table_name, clause, params
    end

    private def build_find_by_clause(criteria : Grant::ModelArgs)
      keys = criteria.keys
      criteria_hash = criteria.dup

      clauses = keys.map do |name|
        if criteria_hash.has_key?(name) && !criteria_hash[name].nil?
          matcher = "= ?"
        else
          matcher = "IS NULL"
          criteria_hash.delete name
        end

        "#{quoted_table_name}.#{quote(name.to_s)} #{matcher}"
      end

      {clauses.join(" AND "), criteria_hash.values}
    end
  end

  # Reloads the record's attributes from the database in place and clears its
  # current and previous dirty state. Raises `Grant::Querying::NotFound` if the
  # record no longer exists in the current scope.
  #
  # ```
  # post = Post.create(name: "Grant Rocks!", body: "Check this out.")
  # # record gets updated by another process
  # post.reload # refreshes this same object from the database
  # ```
  def reload
    fresh = self.class.find!(primary_key_value)

    {% begin %}
      {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
        @{{column.name.id}} = fresh.@{{column.name.id}}
      {% end %}
    {% end %}

    self.new_record = false
    ensure_dirty_tracking_initialized
    @original_attributes.not_nil!.clear
    @changed_attributes.not_nil!.clear
    @previous_changes.not_nil!.clear
    capture_original_attributes

    self
  end
end
