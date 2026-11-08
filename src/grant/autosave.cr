# Autosave for associations: what saving an owner does to the records staged on
# it, and how their validation errors reach the owner.
#
# | Option                 | Default            | Effect on `owner.save`                                                     |
# | ---------------------- | ------------------ | -------------------------------------------------------------------------- |
# | `autosave:` (unset)    |                    | New records are validated and saved with the owner.                        |
# | `autosave: true`       |                    | Also saves changed records, and destroys the ones marked for destruction.  |
# | `autosave: false`      |                    | Never saves the associated records.                                        |
# | `validate:`            | `true` (has_many)  | Validates the new (or, with `autosave: true`, changed) records first.      |
# | `index_errors: true`   | `false`            | Keys errors by position: `posts[0].title` rather than `posts.title`.       |
#
# With `autosave: true` the errors of an invalid record are copied onto the
# owner (`posts.title`), so `owner.save` returns `false` before anything is
# written. Without it the owner gets one `posts` "is invalid" error.
#
# ```
# class Author < Grant::Base
#   has_many :posts, autosave: true, index_errors: true
# end
#
# author.posts.first.mark_for_destruction
# author.posts.build(title: "")
# author.save                      # => false
# author.errors[:"posts[0].title"] # => ["can't be blank"]
# ```
module Grant::Autosave
  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @_marked_for_destruction : Bool = false

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @_autosave_checking : Bool = false

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @_autosave_staged : Hash(String, Array(Grant::Base))?

  # Flags this record to be destroyed when the owner that autosaves it
  # (`autosave: true`) is saved. The record stays in the association until then.
  def mark_for_destruction : Nil
    @_marked_for_destruction = true
  end

  # True after `mark_for_destruction`.
  def marked_for_destruction? : Bool
    @_marked_for_destruction
  end

  # Clears `mark_for_destruction`.
  def reset_destruction : Nil
    @_marked_for_destruction = false
  end

  # Forgets the state that `reload` discards, as in ActiveRecord: the
  # destruction mark, `destroyed_by_association`, and the records built or
  # appended but not saved.
  #
  # :nodoc:
  def _autosave_reset_for_reload : Nil
    @_marked_for_destruction = false
    @_autosave_staged = nil
    self.destroyed_by_association = nil
  end

  # True when saving this record through an association would write something:
  # it is new, has unsaved changes or is marked for destruction.
  def changed_for_autosave? : Bool
    return true if new_record? || changed? || marked_for_destruction?
    # Loaded records can point back at each other; a record already being
    # asked answers for its own changes only.
    return false if @_autosave_checking
    @_autosave_checking = true
    begin
      _autosave_nested_changed?
    ensure
      @_autosave_checking = false
    end
  end

  # True when a record this one autosaves (`autosave: true`) has changes to
  # save. Each such association adds its own check.
  #
  # :nodoc:
  def _autosave_nested_changed? : Bool
    false
  end

  # Remembers a record that was built or appended on the association *name* of
  # an owner that has not saved it, so the owner's save can persist it.
  #
  # :nodoc:
  def _autosave_stage(name : String, record : Grant::Base) : Nil
    staged = (@_autosave_staged ||= {} of String => Array(Grant::Base))
    list = (staged[name] ||= [] of Grant::Base)
    list << record unless list.any?(&.same?(record))
  end

  # :nodoc:
  def _autosave_staged(name : String) : Array(Grant::Base)
    staged = @_autosave_staged
    return [] of Grant::Base unless staged

    staged[name]? || [] of Grant::Base
  end

  # Drops the staged records of *name* that are persisted now.
  #
  # :nodoc:
  def _autosave_unstage_saved(name : String) : Nil
    staged = @_autosave_staged
    return unless staged

    list = staged[name]?
    list.reject!(&.persisted?) if list
  end

  # Copies the errors of the invalid associated *record* onto this record, keyed
  # `association.attribute` (`association[index].attribute` with *index*).
  #
  # :nodoc:
  def _autosave_import_errors(association : String, record : Grant::Base, index : Int32?) : Nil
    Grant::Autosave::AssociationOperations.import_errors(self, association, record, index)
  end
end

module Grant::AssociationOptions
  # Implements the `autosave:`, `validate:` and `index_errors:` association
  # options for every association type.
  module AutosaveCallbacks
    # Emitted by `belongs_to`, `has_one` and `has_many`. Registers:
    #
    # * a validation of the staged records (see `Grant::Autosave`);
    # * for `belongs_to`, a `before_save` that saves a new parent (or a changed
    #   one with `autosave: true`) and copies its key, or destroys a parent
    #   marked for destruction;
    # * for `has_one` and `has_many`, an `after_save` that points the staged
    #   records at the owner, saves the new or changed ones and destroys the
    #   marked ones.
    #
    # Only staged, loaded and changed records are touched; nothing is queried.
    macro setup_autosave(association_name, association_type, target_class, foreign_key, primary_key, autosave, validate, index_errors)
      {%
        autosave_on = autosave == true
        autosave_off = autosave == false
        validating = validate.is_a?(NilLiteral) ? (autosave_on || association_type == :has_many) : (validate ? true : false)
        indexed = index_errors == true
        name = association_name.id.stringify
        owner_key_read = primary_key ? "self.read_attribute(#{primary_key.id.stringify})".id : "self.read_attribute(self.class.primary_name)".id
        record_key_read = primary_key ? "record.read_attribute(#{primary_key.id.stringify})".id : "record.read_attribute(record.class.primary_name)".id
      %}

      # The association's options, as methods so `accepts_nested_attributes_for`
      # can switch autosave on for the associations it feeds.
      private def _autosave_on_{{association_name.id}}? : Bool
        {{autosave_on}}
      end

      private def _autosave_off_{{association_name.id}}? : Bool
        {{autosave_off}}
      end

      private def _autosave_validating_{{association_name.id}}? : Bool
        {{validating}}
      end

      private def _autosave_indexed_{{association_name.id}}? : Bool
        {{indexed}}
      end

      {% if autosave_on %}
        # A change in a loaded record this association autosaves makes the owner
        # count as changed for its own owner's autosave.
        def _autosave_nested_changed? : Bool
          {% if @type.methods.any? { |candidate| candidate.name == "_autosave_nested_changed?" } %}
            return true if previous_def
          {% else %}
            return true if super
          {% end %}
          {% if association_type == :has_many %}
            _autosave_records_{{association_name.id}}.any?(&.changed_for_autosave?)
          {% else %}
            (record = _autosave_record_{{association_name.id}}) ? record.changed_for_autosave? : false
          {% end %}
        end
      {% end %}

      {% if association_type == :has_many %}
        # Every record the association holds in memory: the loaded target plus
        # the ones built or appended on it.
        private def _autosave_records_{{association_name.id}} : Array({{target_class.id}})
          records = [] of {{target_class.id}}
          consume = ->(candidate : Grant::Base) do
            record = candidate.as?({{target_class.id}})
            records << record if record
          end
          Grant::Autosave::AssociationOperations.each_unique_record(self, {{name}}, consume)
          records
        end
      {% else %}
        private def _autosave_record_{{association_name.id}} : {{target_class.id}}?
          Grant::Autosave::AssociationOperations.loaded_record(self, {{name}}).try(&.as?({{target_class.id}}))
        end
      {% end %}

      private def _validate_associated_{{association_name.id}} : Nil
        return unless _autosave_validating_{{association_name.id}}?
        autosaving = _autosave_on_{{association_name.id}}?
        {% if association_type == :has_many %}
          records = _autosave_records_{{association_name.id}}.map { |record| record.as(Grant::Base) }
          Grant::Autosave::AssociationOperations.validate_many(self, {{name}}, {{foreign_key}}, records, autosaving, _autosave_indexed_{{association_name.id}}?)
        {% else %}
          record = _autosave_record_{{association_name.id}}
          Grant::Autosave::AssociationOperations.validate_one(self, {{name}}, {{association_type}}, {{foreign_key}}, record.try(&.as(Grant::Base)), autosaving)
        {% end %}
      end

      validate_method :_validate_associated_{{association_name.id}}

      {% if association_type == :belongs_to %}
        # True while a new parent waits on this record: saving the record saves
        # the parent first, so a missing key is no reason to fail validation.
        def _{{association_name.id}}_assigned_for_autosave? : Bool
          return false if _autosave_off_{{association_name.id}}?
          (record = _autosave_record_{{association_name.id}}) ? record.new_record? : false
        end

        private def _autosave_before_save_{{association_name.id}} : Nil
          return if _autosave_off_{{association_name.id}}?
          if record = _autosave_record_{{association_name.id}}
            autosaving = _autosave_on_{{association_name.id}}?
            if autosaving && record.marked_for_destruction?
              clear_nullable_attribute({{foreign_key}})
              record.destroy if record.persisted?
            elsif record.new_record? || (autosaving && record.changed_for_autosave?)
              record.save!(validate: !_autosave_validating_{{association_name.id}}?)
              self.set_attributes({ {{foreign_key}} => {{record_key_read}} })
            end
          end
        end

        before_save :_autosave_before_save_{{association_name.id}}
      {% elsif association_type == :has_one %}
        private def _autosave_after_save_{{association_name.id}} : Nil
          return if _autosave_off_{{association_name.id}}?
          if record = _autosave_record_{{association_name.id}}
            unless record.destroyed?
              autosaving = _autosave_on_{{association_name.id}}?
              if autosaving && record.marked_for_destruction?
                record.destroy if record.persisted?
              else
                owner_key = {{owner_key_read}}
                key_changed = record.read_attribute({{foreign_key}}) != owner_key
                record.set_attributes({ {{foreign_key}} => owner_key }) if key_changed
                if record.new_record? || key_changed || (autosaving && record.changed_for_autosave?)
                  record.save!(validate: !(_autosave_validating_{{association_name.id}}? && (record.new_record? || record.changed?)))
                end
              end
            end
          end
        end

        after_save :_autosave_after_save_{{association_name.id}}
      {% else %}
        private def _autosave_after_save_{{association_name.id}} : Nil
          return if _autosave_off_{{association_name.id}}?
          autosaving = _autosave_on_{{association_name.id}}?
          validated = _autosave_validating_{{association_name.id}}?
          owner_key = {{owner_key_read}}
          saved_any = false
          destroyed_ids = Set(UInt64).new
          _autosave_records_{{association_name.id}}.each do |record|
            next if record.destroyed?
            if autosaving && record.marked_for_destruction?
              record.destroy if record.persisted?
              destroyed_ids << record.object_id
            else
              key_changed = record.read_attribute({{foreign_key}}) != owner_key
              record.set_attributes({ {{foreign_key}} => owner_key }) if key_changed
              if record.new_record? || key_changed || (autosaving && record.changed_for_autosave?)
                record.save!(validate: !(validated && (record.new_record? || record.changed?)))
                saved_any = true
              end
            end
          end
          unless destroyed_ids.empty?
            if association_loaded?({{name}}) && (loaded = get_loaded_association({{name}}).as?(Array(Grant::Base)))
              loaded.reject! { |candidate| destroyed_ids.includes?(candidate.object_id) }
            end
          end
          _autosave_unstage_saved({{name}}) if saved_any
        end

        after_save :_autosave_after_save_{{association_name.id}}
      {% end %}
    end
  end
end
