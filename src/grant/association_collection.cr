require "./associations/through"

# The `before_add`, `after_add`, `before_remove` and `after_remove` hooks of one
# `has_many` association. A `before_` hook that returns `false` vetoes the
# operation; the `has_many` macro builds these from the association options.
struct Grant::AssociationCallbacks(Target)
  getter before_add : Proc(Target, Bool)?
  getter after_add : Proc(Target, Bool)?
  getter before_remove : Proc(Target, Bool)?
  getter after_remove : Proc(Target, Bool)?

  def initialize(@before_add : Proc(Target, Bool)? = nil, @after_add : Proc(Target, Bool)? = nil,
                 @before_remove : Proc(Target, Bool)? = nil, @after_remove : Proc(Target, Bool)? = nil)
  end
end

# Lazy, owner-scoped collection returned by a has_many association.
class Grant::AssociationCollection(Owner, Target)
  include Enumerable(Target)

  def initialize(@owner : Owner,
                 @foreign_key : (Symbol | String),
                 @through : (Symbol | String | Nil) = nil,
                 @primary_key : (Symbol | String | Nil) = nil,
                 @inverse_of : (Symbol | String | Nil) = nil,
                 @scope : (Grant::Query::Builder(Target) -> Grant::Query::Builder(Target))? = nil,
                 @association_name : String? = nil,
                 @loaded_records : Array(Target)? = nil,
                 _through_delete_all : Proc(Int64)? = nil,
                 @through_source : String? = nil,
                 @strict_loading_option : Bool? = nil,
                 @automatic_inverse : Bool = true,
                 @type_column : String? = nil,
                 @type_value : String? = nil,
                 @dependent : Symbol? = nil,
                 @through_writer : Proc(Grant::Associations::ThroughWriter)? = nil,
                 @callbacks : Grant::AssociationCallbacks(Target)? = nil,
                 @pending : Array(Target)? = nil)
    @writer = nil.as(Grant::Associations::ThroughWriter?)
  end

  # True when the records of this association are cached on the owner.
  def loaded? : Bool
    !@loaded_records.nil?
  end

  # Forgets the cached records so the next read queries again.
  def reset : self
    @loaded_records = nil
    if association_name = @association_name
      owner.reset_association(association_name)
    end
    self
  end

  # Discards the cached records and loads them again with one query.
  def reload : self
    reset
    all
    self
  end

  # Loads the records if they are not loaded yet and returns them.
  def load_target : Array(Target)
    all
  end

  def all(clause = "", params = [] of DB::Any) : Array(Target)
    if clause.empty? && params.empty? && (records = @loaded_records)
      return records
    end
    ensure_lazy_loading_allowed

    start_time = Time.instant
    results = if clause.empty? && params.empty?
                association_relation.select
              else
                scope_clause, scope_params, scope_modifiers = scope_fragments
                sql = [query, scope_clause, clause, scope_modifiers].reject(&.empty?).join(" ")
                all_params = [owner_key]
                if (type_column = @type_column) && (type_value = @type_value)
                  all_params << type_value
                end
                scope_params.each { |value| all_params << value }
                params.each { |value| all_params << value.as(Grant::Columns::Type) }
                Target.raw_all(sql, all_params)
              end
    duration = Time.instant - start_time

    Grant::Logs::Association.info { "Loaded has_many association - #{Owner.name} [#{Target.name}] [fk: #{@foreign_key}] - #{results.size} records (#{duration.total_milliseconds}ms)" }

    inverse = inverse_name
    results.each do |record|
      record.set_loaded_association(inverse, owner) if inverse
      owner._adopt_strict_loading(record, true)
    end
    if clause.empty? && params.empty?
      loaded_records = results.dup
      @loaded_records = loaded_records
      if association_name = @association_name
        owner.set_loaded_association(association_name, loaded_records)
      end
    end
    results
  end

  def each(&block : Target ->)
    all.each { |record| yield record }
  end

  def to_a : Array(Target)
    all
  end

  # Returns the association size as `Int64`, using loaded records when present.
  def size : Int64
    if records = @loaded_records
      records.size.to_i64
    else
      count
    end
  end

  # Returns the database count within the owner's association scope without
  # hydrating records, even when the association target has already been loaded.
  # Returns `Int64`.
  def count : Int64
    ensure_lazy_loading_allowed
    result = association_relation.count
    result.is_a?(Int64) ? result : result.values.sum
  end

  # Loads the records and returns their number, matching Enumerable semantics.
  def length : Int32
    all.size
  end

  def empty? : Bool
    if records = @loaded_records
      records.empty?
    else
      ensure_lazy_loading_allowed
      !association_relation.exists?
    end
  end

  def any? : Bool
    if records = @loaded_records
      !records.empty?
    else
      ensure_lazy_loading_allowed
      association_relation.exists?
    end
  end

  def none? : Bool
    !any?
  end

  def first : Target?
    all.first?
  end

  def first! : Target
    all.first
  end

  def last : Target?
    all.last?
  end

  def last! : Target
    all.last
  end

  def where(**matches) : Grant::Query::Builder(Target)
    ensure_lazy_loading_allowed
    association_relation.where(**matches)
  end

  def find(value) : Target?
    record = if records = @loaded_records
               records.find { |item| item.primary_key_value == value }
             elsif @through
               ensure_lazy_loading_allowed
               all.find { |record| record.primary_key_value == value }
             else
               ensure_lazy_loading_allowed
               association_relation.where(Target.primary_name, :eq, value.as(Grant::Columns::Type)).first
             end
    set_inverse(record) if record
    record
  end

  def find!(value) : Target
    find(value) || raise Grant::Querying::NotFound.new("No #{Target.name} found where #{Target.primary_name} = #{value}")
  end

  def find_by(**args) : Target?
    record = if records = @loaded_records
               records.find do |record|
                 args.to_h.all? { |key, value| record.read_attribute(key.to_s) == value }
               end
             else
               ensure_lazy_loading_allowed
               association_relation.where(**args).first
             end
    set_inverse(record) if record
    record
  end

  def find_by!(**args) : Target
    find_by(**args) || raise Grant::Querying::NotFound.new("No #{Target.name} found where #{args.map { |key, value| "#{key} = #{value}" }.join(" and ")}")
  end

  # Builds a new target from named attributes, wired to this owner. The record
  # is not saved. For a `:through` collection the join row is written when the
  # owner is saved.
  #
  # ```
  # post.comments.build(body: "Hi")
  # post.comments.build(body: "Hi") { |comment| comment.author = "sam" }
  # ```
  def build(**attrs) : Target
    build_record(model_args(attrs)) { }[0]
  end

  # :ditto:
  def build(**attrs, &block : Target ->) : Target
    build_record(model_args(attrs), &block)[0]
  end

  # Builds a new target from an attribute `Hash`.
  def build(attrs : Hash) : Target
    build_record(model_args(attrs)) { }[0]
  end

  # :ditto:
  def build(attrs : Hash, &block : Target ->) : Target
    build_record(model_args(attrs), &block)[0]
  end

  # Builds one target per `Hash` or `NamedTuple` of attributes.
  def build(records : Array) : Array(Target)
    records.map { |attrs| build_record(model_args(attrs)) { }[0] }
  end

  # :ditto:
  def build(records : Array, &block : Target ->) : Array(Target)
    records.map { |attrs| build_record(model_args(attrs), &block)[0] }
  end

  # Builds a target from a `NamedTuple` of attributes.
  def build(attrs : NamedTuple) : Target
    build(**attrs)
  end

  # Builds and saves a target. Raises `Grant::Associations::OwnerNotSaved` when
  # the owner is not persisted; returns the (possibly invalid) record otherwise.
  def create(**attrs) : Target
    create_record(model_args(attrs), false) { }
  end

  # :ditto:
  def create(**attrs, &block : Target ->) : Target
    create_record(model_args(attrs), false, &block)
  end

  # :ditto:
  def create(attrs : Hash) : Target
    create_record(model_args(attrs), false) { }
  end

  # :ditto:
  def create(attrs : Hash, &block : Target ->) : Target
    create_record(model_args(attrs), false, &block)
  end

  # Creates one target per `Hash` or `NamedTuple` of attributes inside a single
  # transaction.
  def create(records : Array) : Array(Target)
    created = [] of Target
    Owner.transaction { records.each { |attrs| created << create_record(model_args(attrs), false) { } } }
    created
  end

  # :ditto:
  def create(attrs : NamedTuple) : Target
    create(**attrs)
  end

  # Like `create` but raises `Grant::RecordNotSaved` (or `Grant::RecordInvalid`)
  # when the target cannot be saved.
  def create!(**attrs) : Target
    create_record(model_args(attrs), true) { }
  end

  # :ditto:
  def create!(**attrs, &block : Target ->) : Target
    create_record(model_args(attrs), true, &block)
  end

  # :ditto:
  def create!(attrs : Hash) : Target
    create_record(model_args(attrs), true) { }
  end

  # :ditto:
  def create!(attrs : Hash, &block : Target ->) : Target
    create_record(model_args(attrs), true, &block)
  end

  # :ditto:
  def create!(records : Array) : Array(Target)
    created = [] of Target
    Owner.transaction { records.each { |attrs| created << create_record(model_args(attrs), true) { } } }
    created
  end

  # :ditto:
  def create!(attrs : NamedTuple) : Target
    create!(**attrs)
  end

  # Associates *record* with this owner and persists it when the owner already
  # exists. Repeated appends of the same record do not issue another save.
  # For a `:through` collection this inserts the join row. A `before_add` hook
  # that returns `false` skips the append.
  def <<(record : Target) : self
    concat([record])
  end

  def append(*records : Target) : self
    concat(records.to_a)
  end

  def push(*records : Target) : self
    append(*records)
  end

  # Associates every record in *records*. A `:through` collection inserts all
  # join rows with one INSERT inside a transaction. When any `before_add` hook
  # returns `false` nothing is added.
  def concat(records : Array(Target)) : self
    return self if records.empty?
    return self unless run_hooks(:before_add, records)

    if @through
      concat_through(records, true)
    elsif records.size > 1 && owner.persisted?
      Owner.transaction { records.each { |record| attach_direct(record) } }
    else
      records.each { |record| attach_direct(record) }
    end
    run_hooks(:after_add, records)
    self
  end

  # Removes *records* from the collection following the association's
  # `dependent:` strategy: `nullify` (the default) clears the foreign key with
  # one UPDATE, `delete_all` deletes the target rows and `destroy` destroys them
  # with callbacks. A `:through` collection deletes the join rows and keeps the
  # targets. Returns the records that were part of the collection.
  def delete(*records : Target) : Array(Target)
    delete_records(records.to_a, resolve_strategy(nil))
  end

  # Destroys matching records and runs their callbacks.
  def destroy(*records : Target) : Array(Target)
    destroy_records(records.to_a)
  end

  # The primary keys of the associated records. Reads the loaded records when
  # present; otherwise plucks only the key column.
  def ids : Array(Grant::Columns::Type)
    if records = @loaded_records
      records.map(&.primary_key_value.as(Grant::Columns::Type))
    else
      ensure_lazy_loading_allowed
      association_relation.ids
    end
  end

  # Replaces the collection with the records whose primary keys are *new_ids*.
  # Blank ids are ignored. Every id is checked with one `WHERE pk IN (...)`
  # query and `Grant::RecordNotFound` is raised when one is missing. The
  # difference is then applied set-based inside one transaction: one write for
  # the removed keys and one for the added keys.
  def ids=(new_ids : Array) : Array
    wanted = normalize_ids(new_ids)
    targets = records_for_ids!(wanted)
    unless owner.persisted?
      # A `:through` collection keeps the targets until the owner is saved.
      concat(targets) if @through
      return new_ids
    end

    current = ids
    current_texts = current.map(&.to_s)
    wanted_texts = wanted.map(&.to_s)

    stale_keys = current.reject { |key| wanted_texts.includes?(key.to_s) }
    added = targets.reject { |record| current_texts.includes?(record.primary_key_value.to_s) }

    Owner.transaction do
      remove_by_keys(stale_keys)
      attach_all(added)
    end
    new_ids
  end

  # Drops blank and duplicate ids, keeping the first spelling of each.
  def normalize_ids(list : Array) : Array(Grant::Columns::Type)
    seen = Set(String).new
    result = [] of Grant::Columns::Type
    list.each do |id|
      next if id.nil?
      next if id.is_a?(String) && id.blank?
      result << id.as(Grant::Columns::Type) if seen.add?(id.to_s)
    end
    result
  end

  # The records for *keys*, found with one `IN` query. Raises
  # `Grant::RecordNotFound` when any key has no row.
  def records_for_ids!(keys : Array(Grant::Columns::Type)) : Array(Target)
    return [] of Target if keys.empty?

    found = in_keys(Target.current_scope, Target.primary_name, keys).select
    if found.size != keys.size
      known = found.map { |record| record.primary_key_value.to_s }
      missing = keys.reject { |key| known.includes?(key.to_s) }
      raise Grant::RecordNotFound.new("Couldn't find all #{Target.name} with '#{Target.primary_name}': (#{keys.join(", ")}) (found #{found.size} results, but was looking for #{keys.size}). Couldn't find #{Target.name} with #{Target.primary_name} #{missing.join(", ")}")
    end
    found
  end

  # For a collection of *join* rows (the `through:` association of another
  # collection): the writer that inserts and deletes join rows for that other
  # collection, whose source association on the join model is *source_name*.
  #
  # :nodoc:
  def through_writer(source_name : String) : Grant::Associations::ThroughWriter
    source = Grant::AssociationRegistry.get(Target.name, source_name) ||
             raise Grant::Associations::ThroughWriteError.new("Cannot resolve source association #{Target.name}##{source_name}")
    unless source[:type] == :belongs_to
      raise Grant::Associations::ThroughWriteError.new("Cannot write through #{Target.name}##{source_name}: the source must be a belongs_to")
    end

    owner_column = @foreign_key.to_s
    target_column = source[:foreign_key]
    insert = ->(owner_key : Grant::Columns::Type, keys : Array(Grant::Columns::Type)) : Nil do
      rows = keys.map do |key|
        row = {} of (String | Symbol) => Grant::Columns::Type
        row[owner_column] = owner_key
        row[target_column] = key
        row
      end
      Target.insert_all(rows)
      nil
    end
    remove = ->(owner_key : Grant::Columns::Type, keys : Array(Grant::Columns::Type)?, destroy : Bool) : Int64 do
      rows = Target.where({owner_column => owner_key})
      rows = Grant::AssociationLoader.where_in(rows, target_column, keys) if keys
      if destroy
        destroyed = 0_i64
        rows.select.each { |row| destroyed += 1 if row.destroy }
        destroyed
      else
        rows.delete_all
      end
    end
    Grant::Associations::ThroughWriter.new(source[:primary_key], insert, remove)
  end

  # Saves the targets that were built or appended while the owner was unsaved
  # and inserts their join rows. Called by the owner's `after_save`.
  #
  # :nodoc:
  def save_pending : self
    if (pending = @pending) && !pending.empty?
      staged = pending.dup
      pending.clear
      persist_through(staged, true)
      staged.each { |record| track_loaded(record) }
    end
    self
  end

  def exists? : Bool
    if records = @loaded_records
      !records.empty?
    elsif @through
      ensure_lazy_loading_allowed
      !all.empty?
    else
      ensure_lazy_loading_allowed
      association_relation.exists?
    end
  end

  def exists?(value : Grant::Columns::Type) : Bool
    !find(value).nil?
  end

  # Clears this association by disassociating its rows using the association's
  # `dependent:` strategy. Target records remain unless the strategy deletes or
  # destroys them.
  def clear : self
    delete_all
    self
  end

  # Destroys every associated record, running callbacks, and returns them.
  def destroy_all : Array(Target)
    destroy_records(all.dup)
  end

  # Removes every associated row without loading it, following *dependent*, or
  # the association's own `dependent:` option when omitted:
  #
  # * `:nullify` (default) clears the foreign key with one UPDATE.
  # * `:delete_all` deletes the target rows with one DELETE.
  # * `:destroy` loads and destroys each record with callbacks.
  #
  # A `:through` collection deletes (or destroys) the join rows and keeps the
  # targets. No `before_remove` or `after_remove` hook runs, as in ActiveRecord.
  # Returns the number of affected rows.
  def delete_all(dependent : Symbol? = nil) : Int64
    strategy = resolve_strategy(dependent)
    count = if @through
              delete_all_through(strategy)
            else
              case strategy
              when :delete_all
                association_relation.delete_all
              when :destroy
                destroyed = 0_i64
                all.dup.each { |record| destroyed += 1 if record.destroy }
                destroyed
              else
                association_relation.update_all(nullify_assignments)
              end
            end
    @loaded_records.try(&.clear)
    sync_loaded_association
    count
  end

  private getter owner

  private def in_keys(relation : Grant::Query::Builder(Target), column : String, keys : Array(Grant::Columns::Type)) : Grant::Query::Builder(Target)
    Grant::AssociationLoader.where_in(relation, column, keys)
  end

  private def model_args(attrs : NamedTuple | Hash) : Grant::ModelArgs
    args = Grant::ModelArgs.new
    attrs.each { |key, value| args[key.to_s] = value.as(Grant::Columns::Type) }
    args
  end

  # Instantiates the target with *args*, the owner's key and the polymorphic
  # type, yields it, and runs the `before_add`/`after_add` hooks. The flag is
  # false when a `before_add` hook vetoed the record.
  private def build_record(args : Grant::ModelArgs, & : Target ->) : Tuple(Target, Bool)
    record = Target.new
    record.set_attributes(args)
    record.set_attributes({@foreign_key.to_s => owner_key}) if !@through && !owner_key.nil?
    if (type_column = @type_column) && (type_value = @type_value)
      record.set_attributes({type_column => type_value})
    end
    yield record
    set_inverse(record)

    built = [record]
    return {record, false} unless run_hooks(:before_add, built)

    @pending.try { |list| list << record }
    track_loaded(record)
    run_hooks(:after_add, built)
    {record, true}
  end

  private def create_record(args : Grant::ModelArgs, bang : Bool, & : Target ->) : Target
    unless owner.persisted?
      raise Grant::Associations::OwnerNotSaved.new(owner, @association_name || Target.name, bang ? "create!" : "create")
    end

    record, added = build_record(args) { |built| yield built }
    return record unless added

    if @through
      persist_through([record], bang)
    elsif bang
      record.save!
    else
      record.save
    end
    record
  end

  # Points a single record at the owner and saves it when needed.
  private def attach_direct(record : Target) : Nil
    key_changed = record.read_attribute(@foreign_key.to_s) != owner_key
    if key_changed && !owner_key.nil?
      record.write_attribute(@foreign_key.to_s, owner_key)
    end
    if (type_column = @type_column) && (type_value = @type_value)
      if record.read_attribute(type_column) != type_value
        record.write_attribute(type_column, type_value)
        key_changed = true
      end
    end
    record.save! if owner.persisted? && (key_changed || !record.persisted?)
    set_inverse(record)
    track_loaded(record)
  end

  # Appends to a `:through` collection. With a saved owner the targets are
  # saved and every join row is inserted by one statement; otherwise they wait
  # on the owner until it is saved.
  private def concat_through(records : Array(Target), bang : Bool) : Nil
    if owner.persisted?
      fresh = records.reject { |record| record.persisted? && @loaded_records.try(&.includes?(record)) }
      persist_through(fresh, bang)
      records.each { |record| track_loaded(record) }
    else
      records.each do |record|
        @pending.try { |list| list << record unless list.includes?(record) }
        track_loaded(record)
      end
    end
  end

  # Saves unsaved targets and inserts the join rows, in one transaction.
  private def persist_through(records : Array(Target), bang : Bool) : Nil
    writer = through_writer
    keys = [] of Grant::Columns::Type
    Owner.transaction do
      records.each do |record|
        unless record.persisted?
          saved = bang ? record.save! : record.save
          next unless saved
        end
        keys << record.read_attribute(writer.target_key)
        @pending.try(&.delete(record))
      end
      writer.insert(owner_key, keys)
    end
  end

  # Adds already persisted *records* with set-based writes: one UPDATE that
  # points them at the owner, or one multi-row join INSERT.
  private def attach_all(records : Array(Target)) : Nil
    return if records.empty?
    return unless run_hooks(:before_add, records)

    if @through
      writer = through_writer
      writer.insert(owner_key, records.map { |record| record.read_attribute(writer.target_key) })
    else
      keys = records.map { |record| record.primary_key_value.as(Grant::Columns::Type) }
      assignments = [{@foreign_key.to_s, owner_key}] of Tuple(String, Grant::Columns::Type)
      if (type_column = @type_column) && (type_value = @type_value)
        assignments << {type_column, type_value.as(Grant::Columns::Type)}
      end
      in_keys(Target.current_scope, Target.primary_name, keys).update_all(assignments)
    end
    records.each do |record|
      set_inverse(record)
      track_loaded(record)
    end
    run_hooks(:after_add, records)
  end

  # Removes the records with primary keys *keys* without loading them, unless a
  # remove hook is declared and needs the records.
  private def remove_by_keys(keys : Array(Grant::Columns::Type)) : Nil
    return if keys.empty?

    strategy = resolve_strategy(nil)
    writer = @through ? through_writer : nil
    if has_remove_hooks? || strategy == :destroy || (writer && writer.target_key != Target.primary_name)
      delete_records(records_for_ids!(keys), strategy)
      return
    end

    if writer
      remove_join_rows(keys, strategy)
    else
      relation = in_keys(association_relation, Target.primary_name, keys)
      if strategy == :delete_all
        relation.delete_all
      else
        relation.update_all(nullify_assignments)
      end
    end
    @loaded_records.try(&.reject! { |record| keys.any? { |key| key.to_s == record.primary_key_value.to_s } })
    sync_loaded_association
  end

  private def delete_records(records : Array(Target), strategy : Symbol) : Array(Target)
    members = records.select { |record| record.persisted? && (@through || member?(record)) }
    return members if members.empty?
    return [] of Target unless run_hooks(:before_remove, members)

    if @through
      writer = through_writer
      remove_join_rows(members.map { |record| record.read_attribute(writer.target_key) }, strategy)
    else
      keys = members.map { |record| record.primary_key_value.as(Grant::Columns::Type) }
      relation = in_keys(association_relation, Target.primary_name, keys)
      case strategy
      when :delete_all
        relation.delete_all
      when :destroy
        Owner.transaction { members.each(&.destroy!) }
      else
        relation.update_all(nullify_assignments)
        members.each do |record|
          record.write_attribute(@foreign_key.to_s, nil)
          @type_column.try { |column| record.write_attribute(column, nil) }
        end
      end
    end
    forget(members)
    run_hooks(:after_remove, members)
    members
  end

  private def destroy_records(records : Array(Target)) : Array(Target)
    members = records.select { |record| record.persisted? && (@through || member?(record)) }
    return members if members.empty?
    return [] of Target unless run_hooks(:before_remove, members)

    removed = [] of Target
    Owner.transaction do
      if @through
        writer = through_writer
        remove_join_rows(members.map { |record| record.read_attribute(writer.target_key) }, resolve_strategy(nil))
      end
      members.each { |record| removed << record if record.destroy! }
    end
    forget(removed)
    run_hooks(:after_remove, removed)
    removed
  end

  private def delete_all_through(strategy : Symbol) : Int64
    writer = through_writer
    keys = if @scope
             association_relation.select.map { |record| record.read_attribute(writer.target_key) }
           end
    remove_join_rows(keys, strategy)
  end

  private def remove_join_rows(keys : Array(Grant::Columns::Type)?, strategy : Symbol) : Int64
    return 0_i64 if keys && keys.empty?

    through_writer.remove(owner_key, keys, strategy == :destroy)
  end

  # The strategy for removing records: *dependent* when given, else the
  # association's `dependent:` option, else `:nullify`.
  private def resolve_strategy(dependent : Symbol?) : Symbol
    if dependent
      unless dependent == :nullify || dependent == :delete_all || dependent == :destroy
        raise ArgumentError.new("Unknown dependent strategy #{dependent.inspect}; use :nullify, :delete_all or :destroy")
      end
      return dependent
    end
    configured = @dependent
    if configured == :destroy
      :destroy
    elsif configured == :delete_all
      :delete_all
    else
      :nullify
    end
  end

  private def nullify_assignments : Array(Tuple(String, Grant::Columns::Type))
    assignments = [{@foreign_key.to_s, nil.as(Grant::Columns::Type)}]
    if type_column = @type_column
      assignments << {type_column, nil.as(Grant::Columns::Type)}
    end
    assignments
  end

  private def member?(record : Target) : Bool
    return true if @loaded_records.try(&.includes?(record))
    return false unless record.read_attribute(@foreign_key.to_s) == owner_key
    if (type_column = @type_column) && (type_value = @type_value)
      return false unless record.read_attribute(type_column) == type_value
    end
    true
  end

  private def track_loaded(record : Target) : Nil
    if records = @loaded_records
      records << record unless records.includes?(record)
      sync_loaded_association
    end
  end

  private def forget(records : Array(Target)) : Nil
    @loaded_records.try { |list| records.each { |record| list.delete(record) } }
    sync_loaded_association
  end

  private def has_remove_hooks? : Bool
    if callbacks = @callbacks
      !(callbacks.before_remove.nil? && callbacks.after_remove.nil?)
    else
      false
    end
  end

  # Runs the hook for *kind* on every record. A `before_` hook that returns
  # `false` vetoes the whole operation, reported as a false result.
  private def run_hooks(kind : Symbol, records : Array(Target)) : Bool
    callbacks = @callbacks
    return true unless callbacks

    hook = case kind
           when :before_add    then callbacks.before_add
           when :after_add     then callbacks.after_add
           when :before_remove then callbacks.before_remove
           else                     callbacks.after_remove
           end
    return true unless hook

    if kind == :before_add || kind == :before_remove
      records.all? { |record| hook.call(record) }
    else
      records.each { |record| hook.call(record) }
      true
    end
  end

  private def through_writer : Grant::Associations::ThroughWriter
    @writer ||= (@through_writer || raise Grant::Associations::ThroughWriteError.new("#{Owner.name}##{@association_name} is not a through association")).call
  end

  private def set_inverse(record : Target) : Target
    if inverse = inverse_name
      record.set_loaded_association(inverse, owner)
    end
    owner._adopt_strict_loading(record, true)
    record
  end

  # The explicit `inverse_of:` name, or the inverse detected from the models'
  # keys (see `Grant::Reflection#inverse_of`).
  private def inverse_name : String?
    if explicit = @inverse_of
      explicit.to_s
    elsif @automatic_inverse && (association_name = @association_name)
      owner._association_inverse(association_name)
    end
  end

  private def sync_loaded_association : Nil
    if association_name = @association_name
      if records = @loaded_records
        owner.set_loaded_association(association_name, records)
      end
    end
  end

  private def ensure_lazy_loading_allowed : Nil
    owner.assert_association_can_lazy_load!(@association_name || Target.name, @strict_loading_option)
  end

  private def owner_key : Grant::Columns::Type
    owner.read_attribute(@primary_key || Owner.primary_name)
  end

  private def association_relation : Grant::Query::Builder(Target)
    relation = Target.current_scope
    if association_scope = @scope
      relation = association_scope.call(relation)
    end
    if @through
      through_metadata, source_metadata = through_associations
      if source_metadata[:type] == :belongs_to
        source_key = through_metadata[:target_class].quote(source_metadata[:foreign_key])
        target_key = source_metadata[:primary_key]
      else
        join_model = through_metadata[:target_class]
        primary_name = join_model.primary_name || raise Grant::Querying::MissingPrimaryKeyError.new("#{join_model.name} has no primary key")
        source_key = join_model.quote(primary_name)
        target_key = source_metadata[:foreign_key]
      end
      join_model = through_metadata[:target_class]
      join_table = join_model.quoted_table_name
      join_owner_key = join_model.quote(through_metadata[:foreign_key])
      subquery = "SELECT #{source_key} FROM #{join_table} WHERE #{join_owner_key} = ?"
      relation.where("#{Target.quote(target_key)} IN (#{subquery})", owner_key)
    else
      relation = relation.where(@foreign_key.to_s, :eq, owner_key)
      if (type_column = @type_column) && (type_value = @type_value)
        relation = relation.where(type_column, :eq, type_value)
      end
      relation
    end
  end

  private def through_associations : Tuple(Grant::AssociationRegistry::AssociationMeta, Grant::AssociationRegistry::AssociationMeta)
    through_name = @through || raise ArgumentError.new("Missing through association metadata")
    source_name = @through_source || raise ArgumentError.new("Missing source association metadata")
    through_metadata = Grant::AssociationRegistry.get(Owner.name, through_name.to_s) || raise ArgumentError.new("Cannot resolve through association #{Owner.name}##{through_name}")
    source_metadata = Grant::AssociationRegistry.get(through_metadata[:target_class].name, source_name) || raise ArgumentError.new("Cannot resolve source association #{through_metadata[:target_class].name}##{source_name}")
    {through_metadata, source_metadata}
  end

  private def scope_fragments : Tuple(String, Array(Grant::Columns::Type), String)
    return {"", [] of Grant::Columns::Type, ""} unless association_scope = @scope

    adapter = Target.adapter
    db_type = if adapter.postgres?
                Grant::Query::Builder::DbType::Pg
              elsif adapter.mysql?
                Grant::Query::Builder::DbType::Mysql
              else
                Grant::Query::Builder::DbType::Sqlite
              end
    builder = Grant::Query::Builder(Target).new(db_type)
    builder = association_scope.call(builder)
    clauses = [] of String
    params = [] of Grant::Columns::Type

    builder.where_fields.each do |field|
      if field.is_a?(NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type))
        operator = SCOPE_OPERATORS[field[:operator].to_s]? || field[:operator].to_s
        column = field[:field]
        column = "#{Target.quote(Target.table_name)}.#{Target.quote(column)}" unless column.includes?(".")
        clauses << "#{column} #{operator} ?"
        params << field[:value]
      elsif field.is_a?(NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type))
        clauses << "(#{field[:stmt]})"
        params << field[:value] unless field[:value].nil?
      end
    end

    where_clause = clauses.empty? ? "" : "AND #{clauses.join(" AND ")}"
    modifiers = [] of String
    unless builder.order_fields.empty?
      order_fields = builder.order_fields.map do |order|
        field = order[:field]
        quoted = field.includes?(".") ? field.split(".").map { |part| Target.quote(part) }.join(".") : Target.quote(field)
        direction = order[:direction] == Grant::Query::Builder::Sort::Descending ? "DESC" : "ASC"
        "#{quoted} #{direction}"
      end
      modifiers << "ORDER BY #{order_fields.join(", ")}"
    end
    modifiers << "LIMIT #{builder.limit}" if builder.limit
    modifiers << "OFFSET #{builder.offset}" if builder.offset
    {where_clause, params, modifiers.join(" ")}
  end

  private def query : String
    if @through.nil?
      type_predicate = if type_column = @type_column
                         " AND #{Target.quote(Target.table_name)}.#{Target.quote(type_column)} = ?"
                       else
                         ""
                       end
      "WHERE #{Target.quote(Target.table_name)}.#{Target.quote(@foreign_key.to_s)} = ?#{type_predicate}"
    else
      through_metadata, source_metadata = through_associations
      join_model = through_metadata[:target_class]
      join_table = join_model.quoted_table_name
      target_table = Target.quoted_table_name
      join_primary_name = join_model.primary_name || raise Grant::Querying::MissingPrimaryKeyError.new("#{join_model.name} has no primary key")
      join_primary_key = join_model.quote(join_primary_name)
      target_join = if source_metadata[:type] == :belongs_to
                      "#{target_table}.#{Target.quote(source_metadata[:primary_key])} = #{join_table}.#{join_model.quote(source_metadata[:foreign_key])}"
                    else
                      "#{target_table}.#{Target.quote(source_metadata[:foreign_key])} = #{join_table}.#{join_primary_key}"
                    end
      "JOIN #{join_table} ON #{target_join} WHERE #{join_table}.#{join_model.quote(through_metadata[:foreign_key])} = ?"
    end
  end

  SCOPE_OPERATORS = {"eq" => "=", "gteq" => ">=", "lteq" => "<=", "neq" => "!=", "ltgt" => "<>", "gt" => ">", "lt" => "<", "ngt" => "!>", "nlt" => "!<", "like" => "LIKE", "nlike" => "NOT LIKE"}
end
