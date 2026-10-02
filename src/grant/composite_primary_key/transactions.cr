# Persistence for models written through a key tuple: a composite primary key
# (`composite_primary_key a, b`) or `query_constraints`.
#
# `Grant::Transactions` writes a record with `WHERE <primary key> = ?`. This
# module is included after it, so a model that declares a composite key or
# query constraints runs these overrides instead, and every statement (INSERT
# for composite keys, UPDATE, DELETE, the reload SELECT, touch, increment!)
# carries one predicate per key column. A model that declares neither falls
# through `super` to the single-key path.
module Grant::CompositePrimaryKey::Transactions
  # Relation over the record's own row: the write scope (`unscoped`, or the
  # tenant scope of a multitenant model) narrowed by every key column, each at
  # the value it has in the database. A NULL key part matches with IS NULL.
  private def __key_scope
    scope = self.class.__multitenant? ? self.class.__tenant_write_scope : self.class.unscoped
    self.class.persistence_key_columns.each do |column|
      value = __key_value_in_database(column)
      if value.nil?
        scope.where!("#{self.class.quoted_table_name}.#{self.class.quote(column)} IS NULL")
      else
        scope.where!(column, :eq, value)
      end
    end
    scope
  end

  # :nodoc:
  protected def __row_key_scope
    return super unless self.class.keyed_by_tuple?
    __key_scope
  end

  private def __key_value_in_database(column : String) : Grant::Columns::Type
    attribute_in_database(column).as(Grant::Columns::Type)
  end

  private def __key_description : String
    self.class.persistence_key_columns.map { |column| "#{column}=#{read_attribute(column)}" }.join(", ")
  end

  private def __create(skip_timestamps : Bool = false)
    return super unless self.class.composite_primary_key?

    {% begin %}
      Grant::Logs::Model.debug { "Creating record - #{self.class.name}" }

      set_timestamps unless skip_timestamps || !self.class.record_timestamps?
      fields = self.class.content_fields.dup
      params = content_values
      generated_column : String? = nil

      {% for ivar in @type.instance_vars.select { |iv| (ann = iv.annotation(Grant::Column)) && ann[:primary] } %}
        {% ann = ivar.annotation(Grant::Column) %}
        if key_part = @{{ivar.name.id}}
          fields << {{ivar.name.stringify}}
          params << key_part
        {% if ann[:auto] == true && ivar.type == UUID? %}
        else
          generated_uuid = {% if ann[:uuid_version] == :v7 %}UUID.v7{% else %}UUID.random{% end %}
          @{{ivar.name.id}} = generated_uuid
          fields << {{ivar.name.stringify}}
          params << generated_uuid
        {% elsif ann[:auto] == true && (ivar.type == Int64? || ivar.type == Int32?) %}
        else
          if generated_column
            message = "Only one auto-generated key column can be unset on insert"
            errors << Grant::Error.new({{ivar.name.stringify}}, message)
            raise DB::Error.new(message)
          end
          generated_column = {{ivar.name.stringify}}
        {% else %}
        else
          message = "Primary key('{{ivar.name}}') cannot be null"
          errors << Grant::Error.new({{ivar.name.stringify}}, message)
          raise DB::Error.new(message)
        {% end %}
        end
      {% end %}

      generated_value = self.class.adapter.insert(self.class.table_name, fields, params, lastval: generated_column)
      if column_name = generated_column
        write_attribute(column_name, generated_value.as(Grant::Columns::Type))
        {% for ivar in @type.instance_vars.select { |iv| (ann = iv.annotation(Grant::Column)) && ann[:primary] && ann[:auto] == true && iv.type == Int32? } %}
          @{{ivar.name.id}} = generated_value.to_i32 if column_name == {{ivar.name.stringify}}
        {% end %}
      end
    {% end %}
  rescue err : Grant::Transaction::ReadOnlyError
    raise err
  rescue err : DB::Error | Grant::StatementInvalid
    Grant::Logs::Model.error { "Failed to create record - #{self.class.name} - #{err.message}" }
    raise err
  rescue err
    Grant::Logs::Model.error { "Failed to create record - #{self.class.name} - #{err.message}" }
    raise DB::Error.new(err.message, cause: err)
  else
    self.new_record = false
    Grant::Logs::Model.info { "Record created - #{self.class.name} [#{__key_description}]" }
  end

  private def __update(skip_timestamps : Bool = false)
    return super unless self.class.keyed_by_tuple?
    return if __update_with_optimistic_lock(skip_timestamps)

    raise Grant::ReadOnlyRecordError.new("#{self.class.name} is marked as read only") if readonly?

    Grant::Logs::Model.debug { "Updating record - #{self.class.name} [#{__key_description}]" }

    fields = self.class.content_fields.dup
    params = content_values

    if self.class.partial_updates? && self.class.__partial_update_safe?
      changed_columns = __changed_column_names
      if changed_columns.empty?
        Grant::Logs::Model.debug { "Skipping update, nothing changed - #{self.class.name} [#{__key_description}]" }
        return
      end
      if !skip_timestamps && self.class.record_timestamps?
        set_timestamps(mode: :update)
        params = content_values
        self.class.update_timestamp_columns.each { |column_name| changed_columns << column_name unless changed_columns.includes?(column_name) }
      end
      kept_fields = [] of String
      kept_params = [] of Grant::Columns::Type
      fields.each_with_index do |field_name, index|
        if changed_columns.includes?(field_name)
          kept_fields << field_name
          kept_params << params[index]
        end
      end
      fields = kept_fields
      params = kept_params
    elsif !skip_timestamps && self.class.record_timestamps?
      set_timestamps(mode: :update)
      params = content_values
    end

    # Do not update creation timestamps on update
    Grant::Timestamps::CREATED_COLUMNS.each do |created_column|
      if created_index = fields.index(created_column)
        fields.delete_at created_index
        params.delete_at created_index
      end
    end

    # `attr_readonly` columns are writable on create and ignored on update.
    self.class.readonly_attributes.each do |readonly_field|
      if readonly_index = fields.index(readonly_field)
        fields.delete_at readonly_index
        params.delete_at readonly_index
      end
    end

    return if fields.empty?

    begin
      assignments = [] of Tuple(String, Grant::Columns::Type)
      fields.each_with_index { |field, index| assignments << {field, params[index]} }
      self.class.mark_write_operation
      affected = __key_scope.update_all(assignments)
      if affected == 0 && self.class.__multitenant? && !self.class._unscoped?
        unless __key_scope.exists?
          raise Grant::TenantMismatchError.new("#{self.class.name} row #{__key_description} is outside the current tenant.")
        end
      end
      Grant::Logs::Model.info { "Record updated - #{self.class.name} [#{__key_description}]" }
    rescue ex : Grant::TenantMismatchError | Grant::NoTenantError | Grant::StatementInvalid | Grant::Transaction::ReadOnlyError
      raise ex
    rescue err
      Grant::Logs::Model.error { "Failed to update record - #{self.class.name} [#{__key_description}] - #{err.message}" }
      raise DB::Error.new(err.message, cause: err)
    end
  end

  private def __destroy
    return super unless self.class.keyed_by_tuple?

    Grant::Logs::Model.debug { "Destroying record - #{self.class.name} [#{__key_description}]" }
    self.class.mark_write_operation
    affected = __key_scope.delete_all
    if affected == 0 && self.class.__multitenant? && !self.class._unscoped?
      raise Grant::TenantMismatchError.new("#{self.class.name} row #{__key_description} is outside the current tenant.")
    end
    @destroyed = true

    Grant::Logs::Model.info { "Record destroyed - #{self.class.name} [#{__key_description}]" }
  end

  def delete : self
    return super unless self.class.keyed_by_tuple?

    guard_writes!
    __ensure_current_tenant!
    raise Grant::ReadOnlyRecordError.new("#{self.class.name} is marked as read only") if readonly?
    enlist_transaction_record

    if persisted?
      self.class.mark_write_operation
      affected = __key_scope.delete_all
      if affected == 0 && self.class.__multitenant? && !self.class._unscoped?
        raise Grant::TenantMismatchError.new("#{self.class.name} row #{__key_description} is outside the current tenant.")
      end
    end

    mark_destroyed
    self
  end

  def update_columns(args : Grant::ModelArgs) : Bool
    return super unless self.class.keyed_by_tuple?

    guard_writes!
    guard_not_destroyed!("update columns of")
    __ensure_current_tenant!
    raise Grant::ReadOnlyRecordError.new("#{self.class.name} is marked as read only") if readonly?
    raise "Cannot update columns on a new record object" unless persisted?
    raise ArgumentError.new("No columns given to update_columns") if args.empty?

    enlist_transaction_record

    string_args = args.to_h.transform_keys(&.to_s)
    readonly_field = string_args.keys.find { |column_name| self.class.readonly_attributes.includes?(column_name) }
    if readonly_field
      raise Grant::ReadOnlyRecordError.new("#{self.class.name}##{readonly_field} is read only")
    end

    # The statement addresses the row by its key as stored, so build the scope
    # before the new values are written to the attributes.
    scope = __key_scope
    assignments = [] of Tuple(String, Grant::Columns::Type)
    fields = [] of String
    string_args.each do |column_name, value|
      write_attribute(column_name, value.as(Grant::Columns::Type))
      fields << column_name
      assignments << {column_name, read_attribute(column_name)}
    end

    self.class.mark_write_operation
    begin
      affected = scope.update_all(assignments)
      if affected == 0 && self.class.__multitenant? && !self.class._unscoped?
        unless __key_scope.exists?
          raise Grant::TenantMismatchError.new("#{self.class.name} row #{__key_description} is outside the current tenant.")
        end
      end
      Grant::Logs::Model.info { "Columns updated - #{self.class.name} [#{__key_description}]" }
    rescue err : Grant::StatementInvalid | Grant::TenantMismatchError
      Grant::Logs::Model.error { "Failed to update_columns - #{self.class.name} [#{__key_description}] - #{err.message}" }
      raise err
    rescue err
      Grant::Logs::Model.error { "Failed to update_columns - #{self.class.name} [#{__key_description}] - #{err.message}" }
      raise DB::Error.new(err.message, cause: err)
    end
    clear_dirty_tracking_for(fields)
    true
  end

  def increment!(field : Symbol | String, by = 1, touch : Bool | Symbol | Array(Symbol) = false) : self
    return super unless self.class.keyed_by_tuple?

    guard_writes!
    guard_not_destroyed!("increment")
    raise Grant::ReadOnlyRecordError.new("#{self.class.name} is marked as read only") if readonly?
    __ensure_current_tenant!
    enlist_transaction_record

    if new_record?
      increment(field, by)
      save(validate: false)
      return self
    end

    attribute_name = field.to_s
    if self.class.readonly_attributes.includes?(attribute_name)
      raise Grant::ReadOnlyRecordError.new("#{self.class.name}##{attribute_name} is read only")
    end

    current_value = read_attribute(attribute_name)
    raise "Cannot increment non-numeric attribute #{field}" unless current_value.is_a?(Number) || current_value.nil?

    scope = __key_scope
    updated_value = (current_value.nil? ? 0 : current_value) + by
    write_attribute(attribute_name, updated_value.as(Grant::Columns::Type))

    touch_time = Grant::Timestamps.current_time
    touched_columns = self.class.__counter_touch_columns(touch)
    self.class.mark_write_operation
    affected = self.class.__apply_counter_update(scope, {attribute_name => by}, touch, touch_time)
    if affected == 0 && self.class.__multitenant? && !self.class._unscoped?
      unless __key_scope.exists?
        raise Grant::TenantMismatchError.new("#{self.class.name} row #{__key_description} is outside the current tenant.")
      end
    end

    touched_columns.each { |column_name| write_attribute(column_name, touch_time) }
    clear_dirty_tracking_for([attribute_name] + touched_columns)
    self
  end

  # Reloads the record's attributes from the database in place, looking the
  # row up by its whole key tuple (so a constrained model cannot reload a row
  # of another tenant).
  def reload
    return super unless self.class.keyed_by_tuple?

    key_scope = self.class.__key_relation
    self.class.persistence_key_columns.each do |column|
      value = __key_value_in_database(column)
      if value.nil?
        key_scope = key_scope.where("#{self.class.quoted_table_name}.#{self.class.quote(column)} IS NULL")
      else
        key_scope = key_scope.where(column, :eq, value)
      end
    end
    fresh = key_scope.first || raise Grant::Querying::NotFound.new("No #{self.class.name} found with key #{__key_description}")

    {% begin %}
      {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
        @{{column.name.id}} = fresh.@{{column.name.id}}
      {% end %}
    {% end %}

    clear_before_type_cast
    self.new_record = false
    clear_loaded_associations
    _autosave_reset_for_reload
    ensure_dirty_tracking_initialized
    original_attributes, changed_attributes, previous_changes = dirty_tracking_hashes
    original_attributes.clear
    changed_attributes.clear
    previous_changes.clear
    capture_original_attributes

    self
  end
end
