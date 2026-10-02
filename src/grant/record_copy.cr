# `dup` and `clone` for records.
#
# ```
# copy = post.dup
# copy.new_record? # => true
# copy.id          # => nil
# copy.save        # INSERT
# ```
module Grant::RecordCopy
  # Returns a new record with the same attributes but no identity, as
  # ActiveRecord's `dup` does: the primary key and creation/update timestamps
  # are cleared, `new_record?` is true, cached associations and dirty history
  # are not carried over, and `after_initialize` callbacks run. The read-only
  # flag is kept. Saving it inserts a new row.
  def dup
    __copy(fresh_identity: true)
  end

  # Returns a copy that keeps the record's identity and state (persisted, same
  # primary key, pending changes). The copy has its own dirty tracking, so
  # assigning on one does not alter the other. Cached associations and
  # serialized column objects are shared, not copied.
  def clone
    __copy(fresh_identity: false)
  end

  private def __copy(*, fresh_identity : Bool)
    copy = self.class.allocate
    copy.as(Void*).copy_from(self.as(Void*), instance_sizeof(self))
    GC.add_finalizer(copy) if copy.responds_to?(:finalize)
    copy.__reset_for_copy(fresh_identity)
    copy
  end

  # Gives a copy made by `dup` / `clone` its own mutable state. A `dup`
  # (*fresh_identity*) also becomes a new record with no primary key,
  # timestamps or cached associations.
  #
  # :nodoc:
  def __reset_for_copy(fresh_identity : Bool) : Nil
    @original_attributes = @original_attributes.try(&.dup)
    @changed_attributes = @changed_attributes.try(&.dup)
    @previous_changes = @previous_changes.try(&.dup)
    @forced_changes = @forced_changes.try(&.dup)
    @aggregation_changes = @aggregation_changes.try(&.dup)
    @_pending_commit_callbacks = @_pending_commit_callbacks.try(&.dup)
    @errors = nil

    {% for ivar in @type.instance_vars %}
      {% if ivar.annotation(Grant::Column) && ivar.type.union_types.any?(&.name.starts_with?("Array(")) %}
        @{{ ivar.name.id }} = @{{ ivar.name.id }}.try(&.dup)
      {% end %}
    {% end %}

    if fresh_identity
      {% for ivar in @type.instance_vars %}
        {% ann = ivar.annotation(Grant::Column) %}
        {% name = ivar.name.stringify %}
        {% if ann && ann[:primary] %}
          @{{ ivar.name.id }} = nil
        {% elsif ann && ivar.type == Time? && ["created_at", "created_on", "updated_at", "updated_on"].includes?(name) %}
          @{{ ivar.name.id }} = nil
        {% elsif name.ends_with?("_for_autosave") || (name.starts_with?("_") && name.ends_with?("_cache")) %}
          @{{ ivar.name.id }} = nil
        {% end %}
      {% end %}
      @loaded_associations = nil
      # Commit callbacks and save results belong to the original's writes.
      @_pending_commit_callbacks = nil
      @last_save_failed_validation = false
      @last_save_statement_error = nil
      self.new_record = true
      restore_destroyed_state(false)
      establish_initial_dirty_baseline
      # A dup is a newly built record, so its `after_initialize` callbacks run,
      # as ActiveRecord's do.
      __after_initialize
    else
      @loaded_associations = @loaded_associations.try(&.dup)
    end
  end
end
