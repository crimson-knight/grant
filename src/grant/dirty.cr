# Dirty tracking API, mirroring ActiveRecord::AttributeMethods::Dirty.
#
# The storage (three hashes for baseline values, pending changes, and the
# changes from the last save) lives in `Grant::Base`, and the `column` macro
# keeps it current from each setter. This module holds the name-keyed methods
# that read and control that storage. The `column` macro generates only thin
# one-line delegators to them, so the per-column code stays small.
#
# ```
# user = User.find!(1)
# user.name = "Jane"
# user.has_changes_to_save?          # => true
# user.attribute_in_database("name") # => "John"
# user.save
# user.saved_change_to_name?(from: "John") # => true
# user.saved_change_to_attribute("name")   # => {"John", "Jane"}
# user.attribute_previously_was("name")    # => "John"
# ```
#
# ## In-place mutation
#
# Arrays (and the objects behind serialized columns) are mutable, so
# `post.tags << "x"` never goes through the setter. Detection is opt-in per
# model and only ever looks at `Array` columns and serialized columns; scalar
# columns are never snapshotted. Crystal `String` is immutable, so it needs no
# detection: every change to a string column goes through its setter.
#
# ```
# class Post < Grant::Base
#   column id : Int64, primary: true
#   column title : String?
#   column tags : Array(String)?
#
#   detect_mutation # every Array / serialized column
#   # detect_mutation :tags # or only the named ones
# end
# ```
module Grant::Dirty
  # Marker for "no from:/to: filter given" in the `saved_change_to_*?` family.
  struct Unfiltered
  end

  UNFILTERED = Unfiltered.new

  # Defines `Model.mutation_detection_columns`, opting the model in to
  # in-place mutation detection. With no names every mutable column
  # (`Array`, serialized) is watched; with names only those are.
  #
  # Watched columns keep a copy of their loaded value, so this costs one
  # `dup` per watched column when a record is loaded or saved and one
  # comparison per watched column when dirty state is read. Models that do
  # not call it pay nothing.
  macro detect_mutation(*names)
    def self.mutation_detection_columns : Array(String)?
      {% if names.empty? %}
        [] of String
      {% else %}
        [{{ names.map(&.id.stringify).splat }}] of String
      {% end %}
    end
  end

  module ClassMethods
    # `nil` unless the model called `detect_mutation`; otherwise the names it
    # was limited to (empty meaning every mutable column).
    def mutation_detection_columns : Array(String)?
      nil
    end

    # The columns in-place mutation detection actually watches for this model.
    # Always empty unless `detect_mutation` was declared, and never includes a
    # scalar column.
    def mutation_detected_attributes : Array(String)
      names = mutation_detection_columns
      return [] of String unless names

      {% begin %}
        watched = [] of String
        {% for ivar in @type.instance_vars %}
          {% if ivar.annotation(Grant::Column) %}
            {% mutable = ivar.type.union_types.any? { |column_type| column_type.name.starts_with?("Array(") } %}
            {% if mutable %}
              watched << {{ ivar.name.stringify }} if names.empty? || names.includes?({{ ivar.name.stringify }})
            {% elsif ivar.name.stringify.starts_with?("_serialized_") %}
              if names.empty? || names.includes?({{ ivar.name.stringify }}) || names.includes?({{ ivar.name.stringify[12..-1] }})
                watched << {{ ivar.name.stringify }}
              end
            {% end %}
          {% end %}
        {% end %}
        watched
      {% end %}
    end
  end

  # -- Before save ----------------------------------------------------------

  # Returns true when a save would write something. Allocation free unless
  # mutation detection is on or `attribute_will_change!` was used.
  def has_changes_to_save? : Bool
    refresh_dirty
    if pending = @changed_attributes
      !pending.empty?
    else
      false
    end
  end

  # Pending changes as `{name => {original, current}}` (a copy).
  def changes_to_save : Hash(String, Tuple(Grant::Base::DirtyValue, Grant::Base::DirtyValue))
    changes
  end

  # Names of the attributes a save would write.
  def changed_attribute_names_to_save : Array(String)
    changed_attributes
  end

  # Pending changes for one attribute, or nil when it is unchanged.
  def attribute_change_to_be_saved(name : String | Symbol) : Tuple(Grant::Base::DirtyValue, Grant::Base::DirtyValue)?
    refresh_dirty
    dirty_tracking_hashes[1][name.to_s]?
  end

  # The attribute values as the database holds them: the original value for
  # every attribute with a pending change.
  def attributes_in_database : Hash(String, Grant::Base::DirtyValue)
    refresh_dirty
    result = {} of String => Grant::Base::DirtyValue
    dirty_tracking_hashes[1].each do |attribute_name, change|
      result[attribute_name] = change[0]
    end
    result
  end

  # The value of *name* in the database (the original when changed, else the
  # current value).
  def attribute_in_database(name : String | Symbol) : Grant::Base::DirtyValue
    refresh_dirty
    if change = dirty_tracking_hashes[1][name.to_s]?
      change[0]
    else
      read_attribute(name.to_s).as(Grant::Base::DirtyValue)
    end
  end

  # -- After save -----------------------------------------------------------

  # Returns `{before, after}` for *name* from the last save, or nil.
  def saved_change_to_attribute(name : String | Symbol) : Tuple(Grant::Base::DirtyValue, Grant::Base::DirtyValue)?
    ensure_dirty_tracking_initialized
    dirty_tracking_hashes[2][name.to_s]?
  end

  # True when *name* changed in the last save, optionally only from and/or to
  # the given values.
  def saved_change_to_attribute?(name : String | Symbol, *, from = UNFILTERED, to = UNFILTERED) : Bool
    if change = saved_change_to_attribute(name)
      dirty_filter_matches?(change[0], from) && dirty_filter_matches?(change[1], to)
    else
      false
    end
  end

  def attribute_previously_changed?(name : String | Symbol, *, from = UNFILTERED, to = UNFILTERED) : Bool
    saved_change_to_attribute?(name, from: from, to: to)
  end

  # The value of *name* before the last save (the current value when the last
  # save did not change it).
  def attribute_previously_was(name : String | Symbol) : Grant::Base::DirtyValue
    if change = saved_change_to_attribute(name)
      change[0]
    else
      read_attribute(name.to_s).as(Grant::Base::DirtyValue)
    end
  end

  # -- Control --------------------------------------------------------------

  # Restores one attribute to its original value and forgets its change.
  def restore_attribute!(name : String | Symbol) : Nil
    restore_attributes([name.to_s])
  end

  # Marks *name* as changed even though it was not assigned, for callers that
  # mutate the value in place and are not using `detect_mutation`. The current
  # value becomes the original; later in-place edits show up in `changes`.
  def attribute_will_change!(name : String | Symbol) : Nil
    refresh_dirty
    attribute_name = name.to_s
    current = read_attribute(attribute_name).as(Grant::Base::DirtyValue)
    originals, pending, _ = dirty_tracking_hashes
    unless pending.has_key?(attribute_name)
      original = originals[attribute_name]? || snapshot_dirty_value(current)
      originals[attribute_name] = original
      pending[attribute_name] = {original, current}
    end
    forced_change_names << attribute_name
  end

  # Forgets the pending changes for the given attributes (all when none are
  # given) and makes their current values the new baseline. Unlike
  # `restore_attributes` the values are kept.
  def clear_attribute_changes(names : Array(String)? = nil) : Nil
    refresh_dirty
    originals, pending, _ = dirty_tracking_hashes
    (names || pending.keys).each do |attribute_name|
      pending.delete(attribute_name)
      @forced_changes.try &.delete(attribute_name)
      originals[attribute_name] = snapshot_dirty_value(read_attribute(attribute_name).as(Grant::Base::DirtyValue))
    end
  end

  # Drops all pending and previous changes and treats the current values as
  # the baseline.
  def clear_changes_information : Nil
    reset_dirty_state(record_previous: false)
  end

  # Moves the pending changes into `saved_changes` and treats the current
  # values as the baseline, as a successful save does (without touching
  # `new_record?`).
  def changes_applied : Nil
    reset_dirty_state(record_previous: true)
  end

  # -- Internals ------------------------------------------------------------

  private def reset_dirty_state(*, record_previous : Bool) : Nil
    refresh_dirty
    originals, pending, previous = dirty_tracking_hashes
    if record_previous
      @previous_changes = pending.dup
    else
      previous.clear
    end
    pending.clear
    originals.clear
    @forced_changes.try &.clear
    capture_original_attributes
  end

  private def dirty_filter_matches?(value : Grant::Base::DirtyValue, filter) : Bool
    filter.is_a?(Unfiltered) || value == filter
  end

  # Independent copy of a mutable value; scalars are returned as is.
  private def snapshot_dirty_value(value : Grant::Base::DirtyValue) : Grant::Base::DirtyValue
    case value
    when String then value.dup
    when Array  then value.dup
    else             value
    end
  end

  # The baseline copy to keep for *name*: a snapshot when in-place mutation
  # detection watches that column, otherwise the value itself.
  private def baseline_dirty_value(name : String, value : Grant::Base::DirtyValue) : Grant::Base::DirtyValue
    names = self.class.mutation_detection_columns
    return value unless names
    return value unless names.empty? || names.includes?(name)
    snapshot_dirty_value(value)
  end

  # Brings the pending changes up to date with values changed in place:
  # attributes flagged by `attribute_will_change!` and, when the model opted
  # in, watched columns compared against their snapshot.
  private def refresh_dirty : Nil
    if forced = @forced_changes
      unless forced.empty?
        pending = dirty_tracking_hashes[1]
        forced.each do |attribute_name|
          if change = pending[attribute_name]?
            pending[attribute_name] = {change[0], snapshot_dirty_value(read_attribute(attribute_name).as(Grant::Base::DirtyValue))}
          end
        end
      end
    end
    refresh_mutations if self.class.mutation_detection_columns
  end

  # Compares one watched value with its snapshot.
  private def sync_mutated_value(name : String, current : Grant::Base::DirtyValue) : Nil
    originals, pending, _ = dirty_tracking_hashes
    return unless originals.has_key?(name)

    original = originals[name]
    if original == current
      pending.delete(name) unless @forced_changes.try(&.includes?(name))
    else
      pending[name] = {original, snapshot_dirty_value(current)}
    end
  end

  # Serialized-column variant of `sync_mutated_value`; *normalize* re-encodes
  # the original raw value the way *current* was encoded.
  private def sync_mutated_serialization(name : String, current : String, normalize : Proc(String, String)) : Nil
    originals, pending, _ = dirty_tracking_hashes
    return unless originals.has_key?(name)

    original = originals[name]
    unchanged = case original
                when String then normalize.call(original) == current
                else             false
                end
    if unchanged
      pending.delete(name) unless @forced_changes.try(&.includes?(name))
    else
      pending[name] = {original, current}
    end
  end

  # Stores the baseline copies for the columns in-place detection watches.
  # Called wherever the baseline is (re)established; a no-op for models that
  # did not opt in.
  private def capture_mutation_baselines : Nil
    names = self.class.mutation_detection_columns || return
    ensure_dirty_tracking_initialized
    originals = dirty_tracking_hashes[0]
    {% begin %}
      {% for ivar in @type.instance_vars %}
        {% if ivar.annotation(Grant::Column) %}
          {% ivar_name = ivar.name.stringify %}
          {% mutable = ivar.type.union_types.any? { |column_type| column_type.name.starts_with?("Array(") } %}
          {% serialized_raw = ivar_name.starts_with?("_serialized_") %}
          {% if mutable %}
            if names.empty? || names.includes?({{ ivar_name }})
              originals[{{ ivar_name }}] = snapshot_dirty_value(@{{ ivar.name.id }}.as(Grant::Base::DirtyValue))
            end
          {% elsif serialized_raw %}
            if names.empty? || names.includes?({{ ivar_name }}) || names.includes?({{ ivar_name[12..-1] }})
              originals[{{ ivar_name }}] = @{{ ivar.name.id }}.as(Grant::Base::DirtyValue)
            end
          {% end %}
        {% end %}
      {% end %}
    {% end %}
  end

  private def refresh_mutations : Nil
    names = self.class.mutation_detection_columns || return
    ensure_dirty_tracking_initialized
    {% begin %}
      {% for ivar in @type.instance_vars %}
        {% if ivar.annotation(Grant::Column) %}
          {% mutable = ivar.type.union_types.any? { |column_type| column_type.name.starts_with?("Array(") } %}
          {% if mutable %}
            if names.empty? || names.includes?({{ ivar.name.stringify }})
              sync_mutated_value({{ ivar.name.stringify }}, @{{ ivar.name.id }}.as(Grant::Base::DirtyValue))
            end
          {% end %}
        {% end %}
      {% end %}

      # Serialized columns: the cached object is edited in place. Compare its
      # serialization with the normalized serialization of the stored raw
      # value, so formatting differences from the database are not changes.
      {% for ivar in @type.instance_vars %}
        {% ivar_name = ivar.name.stringify %}
        {% if ivar_name.starts_with?("_") && ivar_name.ends_with?("_cache") %}
          {% base = ivar_name[1..-7] %}
          {% if @type.instance_vars.any? { |other| other.name.stringify == "_serialized_" + base } %}
            {% klass = ivar.type.union_types.reject { |candidate| candidate == Nil }.first %}
            if names.empty? || names.includes?({{ base }}) || names.includes?({{ "_serialized_" + base }})
              if cached = @{{ ivar.name.id }}
                sync_mutated_serialization(
                  {{ "_serialized_" + base }},
                  @_{{ base.id }}_serializer.serialize(cached),
                  ->(raw : String) { @_{{ base.id }}_serializer.serialize(@_{{ base.id }}_serializer.deserialize(raw, {{ klass }})) })
              end
            end
          {% end %}
        {% end %}
      {% end %}
    {% end %}
  end
end
