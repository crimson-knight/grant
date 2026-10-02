module Grant::Associations
  # Defines `build_<name>`, `create_<name>` and `create_<name>!` for a
  # `belongs_to`, as ActiveRecord does. The parent is built or created from
  # *attributes* and assigned, so the foreign key points at it once it is
  # saved. The owner itself is never saved by these methods.
  #
  # ```
  # post.build_author(name: "Ada")   # => unsaved Author, assigned to post
  # post.create_author(name: "Ada")  # => saved Author; post.author_id is set
  # post.create_author!(name: "Ada") # raises Grant::RecordInvalid when invalid
  # ```
  #
  # :nodoc:
  macro _grant_define_belongs_to_builders(method_name, class_name)
    def build_{{method_name.id}}(**attributes) : {{class_name.id}}
      parent = {{class_name.id}}.new(**attributes)
      self.{{method_name.id}} = parent
      parent
    end

    def create_{{method_name.id}}(**attributes) : {{class_name.id}}
      parent = {{class_name.id}}.create(**attributes)
      self.{{method_name.id}} = parent
      parent
    end

    def create_{{method_name.id}}!(**attributes) : {{class_name.id}}
      parent = {{class_name.id}}.create!(**attributes)
      self.{{method_name.id}} = parent
      parent
    end
  end

  # Defines `build_<name>`, `create_<name>` and `create_<name>!` for a
  # `has_one`. The child gets this record's key as its foreign key and becomes
  # the loaded target; `build_` leaves it unsaved for the owner's save to
  # persist (autosave), `create_` saves it now. A child already attached to a
  # saved owner is displaced the way `dependent:` says: destroyed
  # (`:destroy`), deleted (`:delete`), otherwise its foreign key is cleared.
  # `create_` needs a saved owner and raises `Grant::Associations::OwnerNotSaved`
  # otherwise.
  #
  # :nodoc:
  macro _grant_define_has_one_builders(method_name, class_name, foreign_key_name, dependent)
    private def _grant_displace_{{method_name.id}} : Nil
      return unless persisted?
      existing = {{method_name.id}}
      return if existing.nil? || existing.new_record? || existing.destroyed?
      {% if dependent == :destroy %}
        existing.destroy
      {% elsif dependent == :delete %}
        existing.delete
      {% else %}
        key_column = {{class_name.id}}.primary_name || raise Grant::Querying::MissingPrimaryKeyError.new("#{ {{class_name.id}}.name} has no primary key")
        {{class_name.id}}.where(key_column, :eq, existing.primary_key_value.as(Grant::Columns::Type))
          .update_all([{ {{foreign_key_name}}, nil.as(Grant::Columns::Type) }])
      {% end %}
    end

    def build_{{method_name.id}}(**attributes) : {{class_name.id}}
      child = {{class_name.id}}.new(**attributes)
      _grant_displace_{{method_name.id}}
      self.{{method_name.id}} = child
      child
    end

    def create_{{method_name.id}}(**attributes) : {{class_name.id}}
      raise Grant::Associations::OwnerNotSaved.new(self, {{method_name.id.stringify}}, "create") unless persisted?
      child = {{class_name.id}}.new(**attributes)
      self.class.transaction do
        _grant_displace_{{method_name.id}}
        self.{{method_name.id}} = child
        child.save
      end
      child
    end

    def create_{{method_name.id}}!(**attributes) : {{class_name.id}}
      raise Grant::Associations::OwnerNotSaved.new(self, {{method_name.id.stringify}}, "create!") unless persisted?
      child = {{class_name.id}}.new(**attributes)
      self.class.transaction do
        _grant_displace_{{method_name.id}}
        self.{{method_name.id}} = child
        child.save!
      end
      child
    end
  end
end
