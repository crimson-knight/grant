require "../locking"

module Grant::Locking::Optimistic
  class StaleObjectError < Exception
    getter record_class : String
    getter record_id : String?

    def initialize(record : Grant::Base)
      @record_class = record.class.name
      @record_id = record.primary_key_value.to_s rescue nil

      message = if id = @record_id
                  "Attempted to update a stale #{@record_class} (id: #{id})"
                else
                  "Attempted to update a stale #{@record_class}"
                end

      super(message)
    end
  end

  macro included
    column lock_version : Int32 = 0

    after_update :__increment_lock_version

    # Declared nilable (coalesced to 0 on read) rather than carrying a default
    # value so that `YAML::Serializable` / `JSON::Serializable`'s auto-generated
    # deserialization initializer does not report it as uninitialized when a
    # model that mixes in optimistic locking is widened to `Grant::Base+`.
    # See issues #39/#41.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @lock_version_was : Int32?

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @lock_conflict_retry_count : Int32?

    class_property lock_conflict_max_retries : Int32 = 0

    # Capture lock_version before saving an existing record so __check_lock_version
    # can compare against it in the before_update callback.
    def save(*, validate : Bool = true, skip_timestamps : Bool = false)
      @lock_version_was = lock_version unless new_record?
      super
    end
  end

  def lock_version_was : Int32
    @lock_version_was ||= 0
  end

  def lock_version_changed? : Bool
    lock_version != lock_version_was
  end

  def with_optimistic_retry(max_retries : Int32 = self.class.lock_conflict_max_retries, &block)
    retry_count = 0

    loop do
      begin
        yield
        break
      rescue ex : StaleObjectError
        retry_count += 1
        if retry_count > max_retries
          raise ex
        end

        reload
        @lock_conflict_retry_count = retry_count
      end
    end

    @lock_conflict_retry_count = 0
  end

  # Replaces the normal update with one atomic UPDATE that writes both the
  # record's attributes and the incremented lock version, guarded by the
  # version that was loaded from the database.
  protected def __update_with_optimistic_lock(skip_timestamps : Bool = false) : Bool
    raise Grant::ReadOnlyRecordError.new("#{self.class.name} is marked as read only") if readonly?

    set_timestamps(mode: :update) unless skip_timestamps

    fields = self.class.content_fields.dup
    params = content_values

    if created_at_index = fields.index("created_at")
      fields.delete_at(created_at_index)
      params.delete_at(created_at_index)
    end

    self.class.readonly_attributes.each do |readonly_field|
      next if readonly_field == "lock_version"

      if readonly_index = fields.index(readonly_field)
        fields.delete_at(readonly_index)
        params.delete_at(readonly_index)
      end
    end

    next_lock_version = lock_version_was + 1
    if lock_version_index = fields.index("lock_version")
      params[lock_version_index] = next_lock_version
    else
      fields << "lock_version"
      params << next_lock_version
    end

    assignments = [] of Tuple(String, Grant::Columns::Type)
    fields.each_with_index do |field, index|
      assignments << {field, params[index]}
    end

    record_id = primary_key_value.as(Grant::Columns::Type)
    query = if self.class.__multitenant?
              self.class.__tenant_write_scope
            else
              self.class.unscoped
            end

    affected_rows = query
      .where(self.class.primary_name, :eq, record_id)
      .where("lock_version = ?", lock_version_was.as(Grant::Columns::Type))
      .update_all(assignments)

    if affected_rows == 0
      if self.class.__multitenant? && !self.class._unscoped?
        tenant_record_exists = self.class.__tenant_write_scope
          .where(self.class.primary_name, :eq, record_id)
          .exists?
        unless tenant_record_exists
          raise Grant::TenantMismatchError.new(
            "#{self.class.name} row #{record_id} is outside the current tenant.")
        end
      end

      raise StaleObjectError.new(self)
    end

    true
  rescue ex : StaleObjectError | Grant::TenantMismatchError | Grant::NoTenantError | Grant::ReadOnlyRecordError | Grant::StatementInvalid
    raise ex
  rescue err
    raise DB::Error.new(err.message, cause: err)
  end

  private def __increment_lock_version
    @lock_version = lock_version_was + 1
    @lock_version_was = lock_version
  end

  private def attribute_before_last_save(name : String)
    case name
    when "lock_version"
      lock_version_was
    else
      nil
    end
  end

  def reload
    super
    @lock_version_was = lock_version
    self
  end
end
