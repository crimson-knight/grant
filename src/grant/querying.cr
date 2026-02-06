module Grant::Querying
  class NotFound < Exception
  end

  class NotUnique < Exception
  end

  module ClassMethods
    # Entrypoint for creating a new object from a result set.
    def from_rs(result : DB::ResultSet) : self
      model = new
      model.new_record = false
      model.from_rs result
      model.after_find if model.responds_to?(:after_find)
      model
    end

    def raw_all(clause = "", params = [] of Grant::Columns::Type)
      rows = [] of self
      adapter.select(select_container, clause, params) do |results|
        results.each do
          rows << from_rs(results)
        end
      end
      rows
    end

    # All will return all rows in the database. The clause allows you to specify
    # a WHERE, JOIN, GROUP BY, ORDER BY and any other SQL92 compatible query to
    # your table. The result will be a Collection(Model) object which lazy loads
    # an array of instantiated instances of your Model class.
    # This allows you to take full advantage of the database
    # that you are using so you are not restricted or dummied down to support a
    # DSL.
    # Lazy load prevent running unnecessary queries from unused variables.
    def all(clause = "", params = [] of Grant::Columns::Type, use_primary_adapter = true)
      mark_write_operation if use_primary_adapter == true

      # If we have scoping support, use current_scope
      if responds_to?(:current_scope)
        clean_clause = clause.strip
        # Fall back to raw_all for clauses that the query builder can't handle:
        # - JOIN clauses (e.g. from :through associations)
        # - Multiple parameters (query.where only accepts a single value)
        if clean_clause.includes?("JOIN ") || params.size > 1
          Collection(self).new(->{ raw_all(clause, params) })
        else
          query = current_scope
          if !clean_clause.empty?
            # Handle WHERE clause - strip the WHERE prefix if present
            if clean_clause.starts_with?("WHERE ")
              clean_clause = clean_clause[6..-1]  # Remove "WHERE " prefix
            end
            query.where(clean_clause, params.first? || nil)
          end
          query.select
        end
      else
        Collection(self).new(->{ raw_all(clause, params) })
      end
    end

    # First adds a `LIMIT 1` clause to the query and returns the first result
    def first(clause = "", params = [] of Grant::Columns::Type)
      # If we have scoping support, use current_scope with limit
      if responds_to?(:current_scope)
        clean_clause = clause.strip
        # Fall back to raw_all for clauses that the query builder can't handle:
        # - JOIN clauses (e.g. from :through associations)
        # - Multiple parameters (query.where only accepts a single value)
        if clean_clause.includes?("JOIN ") || params.size > 1
          all([clean_clause, "LIMIT 1"].join(" "), params, false).first?
        else
          query = current_scope
          if !clean_clause.empty?
            # Handle WHERE clause - strip the WHERE prefix if present
            if clean_clause.starts_with?("WHERE ")
              clean_clause = clean_clause[6..-1]  # Remove "WHERE " prefix
            end
            query.where(clean_clause, params.first? || nil)
          end
          query.limit(1).select.first?
        end
      else
        all([clause.strip, "LIMIT 1"].join(" "), params, false).first?
      end
    end

    def first!(clause = "", params = [] of Grant::Columns::Type)
      first(clause, params) || raise NotFound.new("No #{{{@type.name.stringify}}} found with first(#{clause})")
    end

    # find returns the row with the primary key specified. Otherwise nil.
    def find(value)
      first("WHERE #{primary_name} = ?", [value])
    end

    # find returns the row with the primary key specified. Otherwise raises an exception.
    def find!(value)
      find(value) || raise Grant::Querying::NotFound.new("No #{{{@type.name.stringify}}} found where #{primary_name} = #{value}")
    end

    # Returns the first row found that matches *criteria*. Otherwise `nil`.
    def find_by(**criteria : Grant::Columns::Type)
      find_by criteria.to_h
    end

    # :ditto:
    def find_by(criteria : Grant::ModelArgs)
      clause, params = build_find_by_clause(criteria)
      first "WHERE #{clause}", params
    end

    # Returns the first row found that matches *criteria*. Otherwise raises a `NotFound` exception.
    def find_by!(**criteria : Grant::Columns::Type)
      find_by!(criteria.to_h)
    end

    # :ditto:
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
        if clean_clause.includes?("JOIN ") || params.size > 1
          results = all(clause, params, false).to_a
        else
          query = current_scope
          if !clean_clause.empty?
            # Handle WHERE clause - strip the WHERE prefix if present
            if clean_clause.starts_with?("WHERE ")
              clean_clause = clean_clause[6..-1]  # Remove "WHERE " prefix
            end
            query.where(clean_clause, params.first? || nil)
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
      records = all
      if !criteria.empty?
        clause, params = build_find_by_clause(criteria)
        records = all("WHERE #{clause}", params, false)
      end
      
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
      mark_write_operation
      
      if criteria.empty?
        # Delete all records
        sql = "DELETE FROM #{quoted_table_name}"
        result = adapter.open do |db|
          db.exec(sql).rows_affected
        end
        result
      else
        clause, params = build_find_by_clause(criteria)
        sql = adapter.ensure_clause_template("DELETE FROM #{quoted_table_name} WHERE #{clause}")
        result = adapter.open do |db|
          db.exec(sql, args: params).rows_affected
        end
        result
      end
    end

    # Updates updated_at timestamp for all records matching the given criteria
    def touch_all(*fields, time : Time = Time.local(Grant.settings.default_timezone)) : Int64
      time = time.at_beginning_of_second
      
      set_clause = ["#{quote("updated_at")} = ?"]
      values = [time] of Grant::Columns::Type
      
      # Add any additional fields to touch
      fields.each do |field|
        set_clause << "#{quote(field.to_s)} = ?"
        values << time
      end
      
      sql = adapter.ensure_clause_template("UPDATE #{quoted_table_name} SET #{set_clause.join(", ")}")

      mark_write_operation
      rows_affected = adapter.open do |db|
        db.exec(sql, args: values).rows_affected
      end

      rows_affected
    end

    # Updates counter columns for all records
    def update_counters(id : Number | String, counters : Hash(Symbol, Int32)) : Int64
      set_clause = [] of String
      values = [] of Grant::Columns::Type
      
      counters.each do |column, value|
        column_name = quote(column.to_s)
        if value > 0
          set_clause << "#{column_name} = #{column_name} + ?"
        else
          set_clause << "#{column_name} = #{column_name} - ?"
        end
        values << value.abs
      end
      
      return 0_i64 if set_clause.empty?
      
      # Also update the updated_at timestamp
      {% if @type.instance_vars.select { |ivar| ivar.annotation(Grant::Column) && ivar.name == "updated_at" }.size > 0 %}
        set_clause << "#{quote("updated_at")} = ?"
        values << Time.local(Grant.settings.default_timezone).at_beginning_of_second
      {% end %}
      
      sql = adapter.ensure_clause_template("UPDATE #{quoted_table_name} SET #{set_clause.join(", ")} WHERE #{quote(primary_name)} = ?")
      values << id

      mark_write_operation
      rows_affected = adapter.open do |db|
        db.exec(sql, args: values).rows_affected
      end

      rows_affected
    end

    def find_each(clause = "", params = [] of Grant::Columns::Type, batch_size limit = 100, offset = 0, &)
      find_in_batches(clause, params, batch_size: limit, offset: offset) do |batch|
        batch.each do |record|
          yield record
        end
      end
    end

    def find_in_batches(clause = "", params = [] of Grant::Columns::Type, batch_size limit = 100, offset = 0, &)
      if limit < 1
        raise ArgumentError.new("batch_size must be >= 1")
      end

      loop do
        results = all "#{clause} LIMIT ? OFFSET ?", params + [limit, offset], false
        break if results.empty?
        yield results
        offset += limit
      end
    end

    # Returns `true` if a records exists with a PK of *id*, otherwise `false`.
    def exists?(id : Number | String | Nil) : Bool
      return false if id.nil?
      exec_exists "#{primary_name} = ?", [id]
    end

    # Returns `true` if a records exists that matches *criteria*, otherwise `false`.
    def exists?(**criteria : Grant::Columns::Type) : Bool
      exists? criteria.to_h
    end

    # :ditto:
    def exists?(criteria : Grant::ModelArgs) : Bool
      exec_exists *build_find_by_clause(criteria)
    end

    # count returns a count of all the records
    def count : Int32
      scalar "SELECT COUNT(*) FROM #{quoted_table_name}", &.to_s.to_i
    end

    def exec(clause = "")
      mark_write_operation
      adapter.open(&.exec(clause))
    end

    def query(clause = "", params = [] of Grant::Columns::Type, &)
      mark_write_operation
      clause = adapter.ensure_clause_template(clause)
      adapter.open { |db| yield db.query(clause, args: params) }
    end

    def scalar(clause = "", &)
      mark_write_operation
      adapter.open { |db| yield db.scalar(clause) }
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

  # Returns the record with the attributes reloaded from the database.
  #
  # **Note:** this method is only defined when the `Spec` module is present.
  #
  # ```
  # post = Post.create(name: "Grant Rocks!", body: "Check this out.")
  # # record gets updated by another process
  # post.reload # performs another find to fetch the record again
  # ```
  def reload
    {% if !@top_level.has_constant? "Spec" %}
      raise "#reload is a convenience method for testing only, please use #find in your application code"
    {% end %}
    self.class.find!(primary_key_value)
  end
end
