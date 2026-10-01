module Grant::Associations
  # Defines `<singular>_ids` and `<singular>_ids=` for a `has_many`, including
  # `as:` and `through:` collections.
  #
  # The reader returns the keys typed as the target's key column
  # (`Array(Int64)`), plucking only the key column when the collection is not
  # loaded. The writer replaces the members by key (see
  # `Grant::AssociationCollection#ids=`). On an unsaved owner a plain
  # `has_many` stages the records on the owner, whose first save links them.
  #
  # :nodoc:
  macro _grant_define_ids_accessors(method_name, singular_name, through, polymorphic)
    # The primary keys of the associated records, e.g. `user.post_ids`.
    def {{singular_name.id}}_ids
      {{method_name.id}}.typed_ids
    end

    # Assigns the collection by primary keys, e.g. `user.post_ids = [1, 2, 3]`.
    # Raises `Grant::RecordNotFound` when a key has no row. Removed records
    # follow the association's `dependent:` strategy (`nullify` by default),
    # added records are saved with their callbacks, all in one transaction.
    def {{singular_name.id}}_ids=(ids : Array)
      collection = {{method_name.id}}
      {% unless through || polymorphic %}
      unless persisted?
        # Stage the records on the owner; the autosave callback links them on save.
        self.{{method_name.id}} = collection.records_for_ids!(collection.normalize_ids(ids))
        return ids
      end
      {% end %}
      collection.ids = ids
      ids
    end
  end

  # Installs the `dependent:` callbacks of a `has_one` or `has_many` that has a
  # scope, acting on the scoped relation
  # (`has_many :posts, -> { where(published: true) }, dependent: :destroy`
  # destroys the published posts only, as ActiveRecord does). The unscoped forms
  # keep using `Grant::AssociationOptions::DependentCallbacks`.
  #
  # :nodoc:
  macro _grant_scoped_dependent(association_name, association_type, strategy, target_class, foreign_key, primary_key, scope)
    protected def _grant_dependent_relation_{{association_name.id}}
      relation = {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}}))
      {% if scope.args.empty? %}
        relation.{{scope.body}}
      {% else %}
        {{scope}}.call(relation)
      {% end %}
    end

    {% if strategy == :destroy %}
      around_destroy do
        self.class.transaction do
          block.call
        end
      end
      before_destroy do
        reflection = Grant::AssociationRegistry.reflection({{@type.name.stringify}}, {{association_name.id.stringify}})
        _grant_dependent_relation_{{association_name.id}}.select.each do |record|
          record.destroyed_by_association = reflection
          abort!("Failed to destroy dependent {{association_name}}") unless record.destroy
        end
      end
    {% elsif strategy == :delete_all || strategy == :delete %}
      after_destroy do
        _grant_dependent_relation_{{association_name.id}}.delete_all
      end
    {% elsif strategy == :nullify %}
      after_destroy do
        _grant_dependent_relation_{{association_name.id}}.update_all([{ {{foreign_key}}, nil.as(Grant::Columns::Type) }])
      end
    {% elsif strategy == :restrict || strategy == :restrict_with_error %}
      before_destroy do
        if _grant_dependent_relation_{{association_name.id}}.exists?
          {% if association_type == :has_many %}
            abort!("Cannot delete record because of dependent {{association_name.id}}")
          {% else %}
            abort!("Cannot delete record because a dependent {{association_name.id}} exists")
          {% end %}
        end
      end
    {% elsif strategy == :restrict_with_exception %}
      before_destroy do
        if _grant_dependent_relation_{{association_name.id}}.exists?
          raise Grant::Associations::RestrictError.new({{association_name.id.stringify}})
        end
      end
    {% elsif strategy == :destroy_async %}
      {% owner_class = @type %}
      Grant::Dependent.register_destroyer({{@type.name.stringify}}, {{association_name.id.stringify}}, ->(key : Int64 | String) : Int64 do
        # A destroy that rolled back leaves the owner in place: keep its dependents.
        return 0_i64 if {{owner_class}}.where({{primary_key}}, :eq, key.as(Grant::Columns::Type)).exists?
        reflection = Grant::AssociationRegistry.reflection({{@type.name.stringify}}, {{association_name.id.stringify}})
        destroyed = 0_i64
        relation = {{target_class.id}}.where({{foreign_key}}, :eq, key.as(Grant::Columns::Type))
        {% if scope.args.empty? %}
          relation = relation.{{scope.body}}
        {% else %}
          relation = {{scope}}.call(relation)
        {% end %}
        relation.find_each(batch_size: Grant::Dependent::ASYNC_BATCH_SIZE) do |record|
          record.destroyed_by_association = reflection
          destroyed += 1 if record.destroy
        end
        destroyed
      end)

      after_destroy_commit do
        Grant::Dependent.enqueue({{@type.name.stringify}}, {{association_name.id.stringify}}, self.read_attribute({{primary_key}}))
      end
    {% end %}
  end
end
