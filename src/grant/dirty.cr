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
# Arrays, serialized objects and JSON documents are mutable, so
# `post.tags << "x"` never goes through the setter. `Array` columns are always
# compared against a copy taken when the record is loaded or saved, so partial
# updates and `changed?` see an in-place edit; that costs one `dup` per Array
# column. Serialized columns and converter-backed columns holding a mutable
# value (a `Hash`, `Array`, `JSON::Any` or other object) are watched only when
# the model opts in, because each check re-serializes the value. Scalar and
# `String` columns are never snapshotted: every change to them goes through
# their setter.
#
# ```
# class Post < Grant::Base
#   column id : Int64, primary: true
#   column title : String?
#   column tags : Array(String)?       # always watched
#   column options : JSON::Any?
#
#   detect_mutation # also every serialized / mutable-converter column
#   # detect_mutation :options # or only the named ones
# end
# ```
module Grant::Dirty
  # Marker for "no from:/to: filter given" in the `saved_change_to_*?` family.
  struct Unfiltered
  end

  UNFILTERED = Unfiltered.new

  # Defines `Model.mutation_detection_columns`, opting the model in to
  # in-place mutation detection of serialized columns and converter-backed
  # columns that hold a mutable value. With no names every such column is
  # watched; with names only those are. (`Array` columns are always watched.)
  #
  # A watched column is compared, re-serialized, whenever dirty state is read.
  # Models that do not call it pay nothing for those columns.
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

    # The columns in-place mutation detection actually watches for this model:
    # every `Array` column, plus the serialized and mutable converter-backed
    # columns when `detect_mutation` was declared. Never a scalar column.
    def mutation_detected_attributes : Array(String)
      names = mutation_detection_columns

      {% begin %}
        watched = [] of String
        {% for ivar in @type.instance_vars %}
          {% if ivar.annotation(Grant::Column) %}
            {% ann = ivar.annotation(Grant::Column) %}
            {% array = ivar.type.union_types.any? { |column_type| column_type.name.starts_with?("Array(") } %}
            {% if array && !ann[:converter] %}
              watched << {{ ivar.name.stringify }}
            {% elsif ivar.name.stringify.starts_with?("_serialized_") %}
              if names && (names.empty? || names.includes?({{ ivar.name.stringify }}) || names.includes?({{ ivar.name.stringify[12..-1] }}))
                watched << {{ ivar.name.stringify }}
              end
            {% elsif ann[:converter] && (ivar.type.union_types.reject { |column_type| column_type == Nil }.any? { |column_type| column_type.name.starts_with?("Hash(") || column_type.name.starts_with?("Array(") || column_type == JSON::Any || (column_type.class? && column_type != String) }) %}
              if names && (names.empty? || names.includes?({{ ivar.name.stringify }}))
                watched << {{ ivar.name.stringify }}
              end
            {% end %}
          {% end %}
        {% end %}
        watched
      {% end %}
    end

    # True when this model has anything in-place detection could watch. Lets
    # the dirty readers skip the comparison pass for models with only scalar
    # columns.
    def __watches_mutations? : Bool
      {% begin %}
        {% any_array = @type.instance_vars.any? { |ivar| ivar.annotation(Grant::Column) && ivar.type.union_types.any? { |column_type| column_type.name.starts_with?("Array(") } } %}
        {% if any_array %}
          true
        {% else %}
          !mutation_detection_columns.nil?
        {% end %}
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
    changed
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
  #
  # For a `serialized_column` the accessor name (`settings`) or the raw column
  # (`_serialized_settings`) both work; the raw column is re-serialized from the
  # cached object right away, so `changes` and a `save` see the current value.
  def attribute_will_change!(name : String | Symbol) : Nil
    refresh_dirty
    attribute_name = prepare_serialized_attribute(name.to_s)
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
    clear_assigned_attributes
    @forced_changes.try &.clear
    capture_original_attributes
  end

  # Maps a serialized column's accessor name to its raw column and writes the
  # cached object's current serialization into that raw column, so a flagged
  # in-place edit is not left waiting for the before-save hook. Other names are
  # returned unchanged.
  private def prepare_serialized_attribute(name : String) : String
    {% begin %}
      {% for ivar in @type.instance_vars %}
        {% if ivar.annotation(Grant::Column) && ivar.name.stringify.starts_with?("_serialized_") %}
          {% base = ivar.name.stringify[12..-1] %}
          if name == {{ base }} || name == {{ ivar.name.stringify }}
            if cached = @_{{ base.id }}_cache
              @_serialized_{{ base.id }} = @_{{ base.id }}_serializer.serialize(cached)
            end
            return {{ ivar.name.stringify }}
          end
        {% end %}
      {% end %}
    {% end %}
    name
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
  # detection watches that column (always for an Array), otherwise the value itself.
  private def baseline_dirty_value(name : String, value : Grant::Base::DirtyValue) : Grant::Base::DirtyValue
    # Array columns are always watched, so keep an independent copy.
    return value.dup if value.is_a?(Array)
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
          prepare_serialized_attribute(attribute_name)
          if change = pending[attribute_name]?
            pending[attribute_name] = {change[0], snapshot_dirty_value(read_attribute(attribute_name).as(Grant::Base::DirtyValue))}
          end
        end
      end
    end
    refresh_mutations if self.class.__watches_mutations?
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
  # Called wherever the baseline is (re)established; a no-op for models with
  # nothing to watch.
  private def capture_mutation_baselines : Nil
    return unless self.class.__watches_mutations?
    names = self.class.mutation_detection_columns
    ensure_dirty_tracking_initialized
    originals = dirty_tracking_hashes[0]
    {% begin %}
      {% for ivar in @type.instance_vars %}
        {% if ivar.annotation(Grant::Column) %}
          {% ann = ivar.annotation(Grant::Column) %}
          {% ivar_name = ivar.name.stringify %}
          {% array = ivar.type.union_types.any? { |column_type| column_type.name.starts_with?("Array(") } %}
          {% if array && !ann[:converter] %}
            originals[{{ ivar_name }}] = snapshot_dirty_value(@{{ ivar.name.id }}.as(Grant::Base::DirtyValue))
          {% elsif ivar_name.starts_with?("_serialized_") %}
            if names && (names.empty? || names.includes?({{ ivar_name }}) || names.includes?({{ ivar_name[12..-1] }}))
              originals[{{ ivar_name }}] = @{{ ivar.name.id }}.as(Grant::Base::DirtyValue)
            end
          {% elsif ann[:converter] && (ivar.type.union_types.reject { |column_type| column_type == Nil }.any? { |column_type| column_type.name.starts_with?("Hash(") || column_type.name.starts_with?("Array(") || column_type == JSON::Any || (column_type.class? && column_type != String) }) %}
            if names && (names.empty? || names.includes?({{ ivar_name }}))
              originals[{{ ivar_name }}] = {{ ann[:converter] }}.to_db(@{{ ivar.name.id }}).as(Grant::Base::DirtyValue)
            end
          {% end %}
        {% end %}
      {% end %}
    {% end %}
  end

  private def refresh_mutations : Nil
    names = self.class.mutation_detection_columns
    ensure_dirty_tracking_initialized
    {% begin %}
      {% for ivar in @type.instance_vars %}
        {% if ivar.annotation(Grant::Column) %}
          {% ann = ivar.annotation(Grant::Column) %}
          {% ivar_name = ivar.name.stringify %}
          {% array = ivar.type.union_types.any? { |column_type| column_type.name.starts_with?("Array(") } %}
          {% if array && !ann[:converter] %}
            sync_mutated_value({{ ivar_name }}, @{{ ivar.name.id }}.as(Grant::Base::DirtyValue))
          {% elsif ann[:converter] && !ivar_name.starts_with?("_serialized_") && (ivar.type.union_types.reject { |column_type| column_type == Nil }.any? { |column_type| column_type.name.starts_with?("Hash(") || column_type.name.starts_with?("Array(") || column_type == JSON::Any || (column_type.class? && column_type != String) }) %}
            # A converter-backed mutable value (a Hash, JSON document...):
            # compare its stored form with the baseline taken at load or save.
            if names && (names.empty? || names.includes?({{ ivar_name }}))
              sync_mutated_value({{ ivar_name }}, {{ ann[:converter] }}.to_db(@{{ ivar.name.id }}).as(Grant::Base::DirtyValue))
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
            if names && (names.empty? || names.includes?({{ base }}) || names.includes?({{ "_serialized_" + base }}))
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
