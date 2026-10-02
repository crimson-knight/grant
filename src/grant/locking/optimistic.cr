require "../locking"

module Grant::Locking::Optimistic
  class StaleObjectError < Grant::ErrorBase
    getter record_class : String
    getter record_id : String?

    # *operation* names the write that found the row changed or gone: "update"
    # (also used for touch) or "destroy".
    def initialize(record : Grant::Base, operation : String = "update")
      @record_class = record.class.name
      @record_id = record.primary_key_value.to_s rescue nil

      message = if id = @record_id
                  "Attempted to #{operation} a stale #{@record_class} (id: #{id})"
                else
                  "Attempted to #{operation} a stale #{@record_class}"
                end

      super(message)
    end
  end

  # Class-body macros every model can use before it includes the module.
  module Declaration
    macro included
      extend ClassMethods
    end

    module ClassMethods
      # Whether writes on this model check and bump a lock version. False for
      # models that do not include `Grant::Locking::Optimistic`.
      def locking_enabled? : Bool
        false
      end
    end

    # Names the column that holds the optimistic lock version (an `Int32`
    # that defaults to 0) and declares it. It must come before
    # `include Grant::Locking::Optimistic`, which otherwise declares
    # `lock_version`.
    #
    # ```
    # class Account < Grant::Base
    #   locking_column :revision
    #   include Grant::Locking::Optimistic
    # end
    # ```
    macro locking_column(name)
      {% if @type.ancestors.any? { |ancestor| ancestor.stringify == "Grant::Locking::Optimistic" } %}
        {% raise "locking_column #{name} must be declared before `include Grant::Locking::Optimistic` in #{@type.name}" %}
      {% end %}
      LOCKING_COLUMN = {{name.id.stringify}}
      column {{name.id}} : Int32 = 0
    end
  end

  macro included
    {% locking_name = @type.has_constant?("LOCKING_COLUMN") ? @type.constant("LOCKING_COLUMN").id.stringify : "lock_version" %}
    # `locking_column` already declared the column for a custom name.
    {% unless @type.has_constant?("LOCKING_COLUMN") %}
      column lock_version : Int32 = 0
    {% end %}

    # The column that holds the lock version.
    def self.locking_column : String
      {{locking_name}}
    end

    # Reached only by a `locking_column :name` written after the include (the
    # macro of that name is shadowed by the reader above once the module is in).
    def self.locking_column(name) : NoReturn
      \{% raise "locking_column must be declared before `include Grant::Locking::Optimistic` in #{@type.name}" %}
    end

    # Set to false to stop checking and bumping the version (ActiveRecord's
    # `lock_optimistically`); the column then behaves like any other.
    class_property lock_optimistically : Bool = true

    def self.locking_enabled? : Bool
      lock_optimistically
    end

    private def __locking_version : Int32
      @{{locking_name.id}} || 0
    end

    private def __locking_version=(version : Int32) : Int32
      @{{locking_name.id}} = version
    end

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

    # True when the last update found nothing to write and so left the version
    # alone.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @lock_write_skipped : Bool?

    class_property lock_conflict_max_retries : Int32 = 0

    # Capture lock_version before saving an existing record so __check_lock_version
    # can compare against it in the before_update callback.
    def save(*, validate : Bool = true, skip_timestamps : Bool = false, context : Symbol | Array(Symbol) | Nil = nil)
      @lock_version_was = __locking_version unless new_record?
      super
    end
  end

  def lock_version_was : Int32
    @lock_version_was ||= 0
  end

  def lock_version_changed? : Bool
    __locking_version != lock_version_was
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
    return false unless self.class.locking_enabled?
    raise Grant::ReadOnlyRecordError.new("#{self.class.name} is marked as read only") if readonly?

    # Like the plain update path, write only what changed. A clean record issues
    # no SQL at all, neither bumping the lock version nor `updated_at`.
    changed_columns = nil
    @lock_write_skipped = false
    if self.class.partial_updates? && self.class.__partial_update_safe?
      changed_columns = __changed_column_names
      if changed_columns.empty?
        @lock_write_skipped = true
        return true
      end
    end

    set_timestamps(mode: :update) unless skip_timestamps || !self.class.record_timestamps?

    fields = self.class.content_fields.dup
    params = content_values

    if changed_columns
      kept_fields = [] of String
      kept_params = [] of Grant::Columns::Type
      stamped = skip_timestamps || !self.class.record_timestamps? ? [] of String : self.class.update_timestamp_columns
      fields.each_with_index do |field, index|
        if changed_columns.includes?(field) || stamped.includes?(field) || field == self.class.locking_column
          kept_fields << field
          kept_params << params[index]
        end
      end
      fields = kept_fields
      params = kept_params
    end

    Grant::Timestamps::CREATED_COLUMNS.each do |created_column|
      if created_index = fields.index(created_column)
        fields.delete_at(created_index)
        params.delete_at(created_index)
      end
    end

    self.class.readonly_attributes.each do |readonly_field|
      next if readonly_field == self.class.locking_column

      if readonly_index = fields.index(readonly_field)
        fields.delete_at(readonly_index)
        params.delete_at(readonly_index)
      end
    end

    next_lock_version = lock_version_was + 1
    locking_column = self.class.locking_column
    if lock_version_index = fields.index(locking_column)
      params[lock_version_index] = next_lock_version
    else
      fields << locking_column
      params << next_lock_version
    end

    assignments = [] of Tuple(String, Grant::Columns::Type)
    fields.each_with_index do |field, index|
      assignments << {field, params[index]}
    end

    affected_rows = __version_guarded_scope(lock_version_was).update_all(assignments)
    __raise_stale_record!("update") if affected_rows == 0

    true
  rescue ex : StaleObjectError | Grant::TenantMismatchError | Grant::NoTenantError | Grant::ReadOnlyRecordError | Grant::StatementInvalid
    raise ex
  rescue err
    raise DB::Error.new(err.message, cause: err)
  end

  # Deletes the row only while it still has the version this record loaded, so
  # a concurrent update or destroy is caught by the affected-row count without
  # reading the row first.
  private def __destroy
    return super unless self.class.locking_enabled?

    affected_rows = __version_guarded_scope(__locking_version).delete_all
    __raise_stale_record!("destroy") if affected_rows == 0
    @destroyed = true
  end

  # Touch is a write, so it checks and bumps the version like an update: the
  # version bump runs first (one guarded UPDATE), then the normal touch writes
  # the timestamps.
  def touch(*fields, time : Time = Grant::Timestamps.current_time) : Bool
    if self.class.locking_enabled? && persisted? && !readonly? && !self.class.no_touching?
      current_version = __locking_version
      affected_rows = __version_guarded_scope(current_version)
        .update_all([{self.class.locking_column, (current_version + 1).as(Grant::Columns::Type)}])
      __raise_stale_record!("update") if affected_rows == 0

      self.__locking_version = current_version + 1
      @lock_version_was = current_version + 1
      clear_dirty_tracking_for([self.class.locking_column])
    end
    super
  end

  # The primary-key relation for this row, further limited to *version*.
  private def __version_guarded_scope(version : Int32)
    __row_key_scope
      .where("#{self.class.quote(self.class.locking_column)} = ?", version.as(Grant::Columns::Type))
  end

  # Called when a version-guarded write changed no row: the row is either
  # outside the current tenant or was changed or removed by someone else.
  private def __raise_stale_record!(operation : String) : NoReturn
    if self.class.__multitenant? && !self.class._unscoped?
      tenant_record_exists = self.class.__tenant_write_scope
        .where(self.class.primary_name, :eq, primary_key_value.as(Grant::Columns::Type))
        .exists?
      unless tenant_record_exists
        raise Grant::TenantMismatchError.new(
          "#{self.class.name} row #{primary_key_value} is outside the current tenant.")
      end
    end

    raise StaleObjectError.new(self, operation)
  end

  private def __increment_lock_version
    return unless self.class.locking_enabled?
    return if @lock_write_skipped
    self.__locking_version = lock_version_was + 1
    @lock_version_was = __locking_version
  end

  private def attribute_before_last_save(name : String)
    if name == self.class.locking_column
      lock_version_was
    end
  end

  def reload
    super
    @lock_version_was = __locking_version
    self
  end
end
