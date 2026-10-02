# Improved nested attributes implementation with explicit types
module Grant::NestedAttributes
  macro included
    # Storage for nested attributes data.
    # Declared nilable (with lazy initialization in `_nested_attributes_data`
    # below) rather than carrying a default value so that `YAML::Serializable` /
    # `JSON::Serializable`'s auto-generated deserialization initializer — included
    # on the abstract `Grant::Base` — does not report it as uninitialized for
    # `Grant::Base+`. See issues #39/#41.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_nested_attributes_data : Hash(String, Array(Hash(String, Grant::Columns::Type)))?

    protected def _nested_attributes_data : Hash(String, Array(Hash(String, Grant::Columns::Type)))
      @_nested_attributes_data ||= {} of String => Array(Hash(String, Grant::Columns::Type))
    end

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_grant_nested_owner_foreign_keys_to_skip : Array(String)?

    def _grant_skip_nested_owner_foreign_key_validation(foreign_key : String) : Nil
      keys = @_grant_nested_owner_foreign_keys_to_skip ||= [] of String
      keys << foreign_key unless keys.includes?(foreign_key)
    end

    def _grant_nested_owner_foreign_key_skipped?(foreign_key : String) : Bool
      @_grant_nested_owner_foreign_keys_to_skip.try(&.includes?(foreign_key)) || false
    end

    def _grant_nested_saves_enabled? : Bool
      false
    end

    # Track if we have nested attributes to avoid unnecessary overhead.
    # Nilable for the same reason as above; `nil` is treated as `false`.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_has_nested_attributes : Bool = false
  end

  # Macro to enable automatic nested saves via callbacks
  # Call this after all accepts_nested_attributes_for declarations
  macro enable_nested_saves
    def _grant_nested_saves_enabled? : Bool
      true
    end

    after_save :save_all_nested_attributes

    private def save_all_nested_attributes
      return true unless @_has_nested_attributes
      return true if _nested_attributes_data.empty?

      success = true

      # Process each association's nested attributes
      {% for method in @type.methods.select(&.name.starts_with?("save_nested_")) %}
        {% assoc_name = method.name.gsub(/^save_nested_/, "") %}
        if attrs = _nested_attributes_data[{{ assoc_name.stringify }}]?
          success = {{ method.name.id }} && success
        end
      {% end %}
      # Clear nested data after processing
      _nested_attributes_data.clear if success

      success
    end
  end

  # Lets `<association>_attributes=` create, update and destroy the associated
  # records together with this one, in the shape web forms submit.
  #
  # Declare the association first, then:
  #
  # ```
  # class Author < Grant::Base
  #   has_many :posts
  #   has_one :profile
  #   belongs_to :publisher
  #
  #   accepts_nested_attributes_for posts : Post, allow_destroy: true, reject_if: :all_blank, limit: 5
  #   accepts_nested_attributes_for profile : Profile, update_only: true
  #   accepts_nested_attributes_for publisher : Publisher,
  #     reject_if: ->(attrs : Hash(String, Grant::Columns::Type)) { attrs["name"]?.nil? }
  #   enable_nested_saves
  # end
  #
  # author.posts_attributes = [{id: 1, title: "Edited"}, {id: 2, _destroy: true}, {title: "New"}]
  # author.save
  # ```
  #
  # Options:
  #
  # * `allow_destroy:` honors `_destroy` keys.
  # * `update_only:` updates the existing record of a one-to-one association
  #   instead of replacing it.
  # * `limit:` raises `ArgumentError` for more records than that.
  # * `reject_if:` skips attribute hashes that are `:all_blank`, that a proc
  #   `->(attrs : Hash(String, Grant::Columns::Type)) { ... }` answers `true` for,
  #   or that the named instance method answers `true` for.
  #
  # Submitted ids are checked against the association when the setter runs, with
  # one `WHERE id IN (...)` query, and `Grant::RecordNotFound` is raised for an id
  # that is not part of it. Errors of an invalid nested record land on the owner
  # as `posts.title`, or `posts[0].title` when the association has `index_errors:
  # true`. A `belongs_to` parent is built or updated in memory and saved before
  # this record, through the association's autosave.
  macro accepts_nested_attributes_for(association, **options)
    {%
      # Extract association name and class from the declaration
      if association.is_a?(TypeDeclaration)
        assoc_name = association.var
        target_class = association.type
      else
        # Require explicit type declaration for compile-time safety
        raise "accepts_nested_attributes_for requires explicit type declaration. Use: accepts_nested_attributes_for #{association} : ClassName"
      end

      # The association macro records its kind on the reader it generates.
      assoc_type = nil
      @type.methods.each do |candidate|
        if candidate.name.stringify == assoc_name.stringify
          relationship = candidate.annotation(Grant::Relationship)
          assoc_type = relationship[:type] if relationship
        end
      end
      reject = options[:reject_if]
    %}

    # Flag that this model has nested attributes
    @_has_nested_attributes = true

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_{{assoc_name.id}}_nested_owner_was_new : Bool? = nil

    # The records the submitted ids resolved to, kept for the save.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_{{assoc_name.id}}_nested_existing : Hash(String, {{target_class.id}})?

    private def _{{assoc_name.id}}_nested_rejector : Proc(Hash(String, Grant::Columns::Type), Bool)?
      {% if reject.is_a?(SymbolLiteral) && reject != :all_blank %}
        ->(attrs : Hash(String, Grant::Columns::Type)) { {{reject.id}}(attrs) }
      {% elsif reject.is_a?(ProcLiteral) || reject.is_a?(Call) || reject.is_a?(Var) %}
        {{reject}}
      {% else %}
        nil
      {% end %}
    end

    # Generate the attributes setter method
    def {{assoc_name.id}}_attributes=(attributes)
      @_has_nested_attributes = true

      # Configuration for this specific association
      config = {
        allow_destroy: {{ options[:allow_destroy] || false }},
        update_only: {{ options[:update_only] || false }},
        limit: {{ options[:limit] }},
        reject_if: {% if reject == :all_blank %} :all_blank {% else %} nil {% end %}
      }
      rejector = _{{assoc_name.id}}_nested_rejector

      processed_attrs = case attributes
      when Array
        # Check limit
        if limit = config[:limit]
          if attributes.size > limit
            raise ArgumentError.new("Maximum #{limit} records are allowed. Got #{attributes.size} records instead.")
          end
        end

        attributes.compact_map do |a|
          next unless a.is_a?(Hash) || a.is_a?(NamedTuple)
          process_single_nested_attributes(a, config, rejector)
        end
      when Hash, NamedTuple
        result = process_single_nested_attributes(attributes, config, rejector)
        result ? [result] : [] of Hash(String, Grant::Columns::Type)
      else
        raise ArgumentError.new("Nested attributes must be an Array, Hash, or NamedTuple")
      end

      @_{{assoc_name.id}}_nested_owner_was_new = self.new_record?
      _nested_attributes_data[{{ assoc_name.stringify }}] = processed_attrs

      {% if assoc_type == :belongs_to %}
        assign_nested_{{assoc_name.id}}_parent(processed_attrs.first?)
      {% elsif assoc_type == :has_many || assoc_type == :has_one %}
        load_nested_{{assoc_name.id}}_records(processed_attrs)
      {% end %}
    end

    {% if assoc_type == :belongs_to %}
      # A parent is built or updated in memory; the association's autosave
      # validates and saves it before this record.
      private def _autosave_on_{{assoc_name.id}}? : Bool
        true
      end

      private def _autosave_validating_{{assoc_name.id}}? : Bool
        true
      end

      private def assign_nested_{{assoc_name.id}}_parent(attrs : Hash(String, Grant::Columns::Type)?) : Nil
        return unless attrs
        update_only = {{ options[:update_only] || false }}
        destroy_requested = {{ options[:allow_destroy] || false }} && should_destroy?(attrs)
        id = attrs["id"]?
        id = nil if id.nil? || (id.is_a?(String) && id.blank?)
        assignable = {} of String => Grant::Columns::Type
        attrs.each { |key, value| assignable[key] = value unless key == "id" || key == "_destroy" }

        current = self.{{assoc_name.id}}
        if current && (update_only || (id && current.primary_key_value.to_s == id.to_s))
          self.{{assoc_name.id}} = current
          if destroy_requested
            current.mark_for_destruction
          else
            current.set_attributes(assignable)
          end
        elsif id
          raise Grant::RecordNotFound.new("Couldn't find {{target_class.id}} with #{{{target_class.id}}.primary_name}=#{id} for #{self.class.name} with #{self.class.primary_name}=#{primary_key_value}")
        elsif !destroy_requested && !(update_only && persisted?)
          parent = {{target_class.id}}.new
          parent.set_attributes(assignable)
          self.{{assoc_name.id}} = parent
        end
      end
    {% elsif assoc_type == :has_many || assoc_type == :has_one %}
      # Resolves the submitted ids with one IN query (or the loaded records) and
      # raises `Grant::RecordNotFound` for an id outside this association.
      private def load_nested_{{assoc_name.id}}_records(list : Array(Hash(String, Grant::Columns::Type))) : Nil
        keys = [] of Grant::Columns::Type
        list.each do |attrs|
          id = attrs["id"]?
          keys << id unless id.nil? || (id.is_a?(String) && id.blank?)
        end
        @_{{assoc_name.id}}_nested_existing = nil
        return if keys.empty?

        {% if assoc_type == :has_many %}
          found = self.{{assoc_name.id}}.records_for_ids(keys)
        {% else %}
          foreign_key = self.class._{{assoc_name.id}}_association_meta[:foreign_key]
          found = if key = read_attribute(self.class.primary_name)
                    Grant::AssociationLoader.where_in({{target_class.id}}.where(foreign_key, :eq, key), {{target_class.id}}.primary_name, keys).select
                  else
                    [] of {{target_class.id}}
                  end
        {% end %}
        by_id = {} of String => {{target_class.id}}
        found.each { |record| by_id[record.primary_key_value.to_s] = record }
        missing = keys.reject { |key| by_id.has_key?(key.to_s) }
        unless missing.empty? || {{ options[:update_only] || false }}
          raise Grant::RecordNotFound.new("Couldn't find {{target_class.id}} with #{{{target_class.id}}.primary_name}=#{missing.join(", ")} for #{self.class.name} with #{self.class.primary_name}=#{primary_key_value}")
        end
        @_{{assoc_name.id}}_nested_existing = by_id
      end
    {% end %}

    # Validate the child records before the owner is saved and carry their
    # errors onto the owner, matching the nested-save validation contract.
    {% if assoc_type != :belongs_to %}
    validate "nested {{assoc_name.id}} attributes are valid" do |owner|
      nested_valid = true
      if nested_records = owner._nested_attributes_data[{{ assoc_name.stringify }}]?
        indexed = Grant::AssociationRegistry.reflection(owner.class.name, {{ assoc_name.stringify }}).try(&.options["index_errors"]?) == "true"
        nested_records.each_with_index do |attrs, position|
          destroy_value = attrs["_destroy"]?
          destroy_requested = case destroy_value
                              when Bool         then destroy_value
                              when String       then destroy_value == "true" || destroy_value == "1"
                              when Int32, Int64 then destroy_value == 1
                              else                   false
                              end
          next if {{options[:allow_destroy] || false}} && destroy_requested

          validation_attributes = {} of String => Grant::Columns::Type
          attrs.each do |key, value|
            next if key == "id" || key == "_destroy"
            validation_attributes[key] = value
          end

          submitted_id = attrs["id"]?
          nested_record = if submitted_id && (existing = owner.@_{{assoc_name.id}}_nested_existing.try(&.[submitted_id.to_s]?))
                            existing
                          else
                            {{target_class}}.new
                          end
          nested_record.set_attributes(validation_attributes)

          if owner.new_record? && owner._grant_nested_saves_enabled?
            if association = Grant::AssociationRegistry.get(owner.class.name, {{assoc_name.stringify}})
              if association[:type] == :has_many || association[:type] == :has_one
                nested_record._grant_skip_nested_owner_foreign_key_validation(association[:foreign_key])
              end
            end
          end

          unless nested_record.valid?
            prefix = indexed ? "{{assoc_name.id}}[#{position}]" : "{{assoc_name.id}}"
            nested_record.errors.each do |error|
              owner.errors << Grant::Error.new("#{prefix}.#{error.field}", error.message, error.type)
            end
            nested_valid = false
          end
        end
      end
      nested_valid
    end
    {% end %}

    # Get nested attributes (for testing)
    def {{assoc_name.id}}_nested_attributes
      _nested_attributes_data[{{ assoc_name.stringify }}]?
    end

    # Resolve IDs through this owner's association so another parent's
    # records cannot be updated or destroyed by submitting their primary key.
    # The records were resolved when the attributes were assigned; only an
    # association that was not known then falls back to loading it.
    private def find_nested_{{assoc_name.id}}_by_id(id : Grant::Columns::Type) : {{target_class.id}}?
      if resolved = @_{{assoc_name.id}}_nested_existing
        return resolved[id.to_s]?
      end
      association = self.{{assoc_name.id}}
      if association.responds_to?(:all)
        association.all.to_a.find do |record|
          record.primary_key_value.to_s == id.to_s
        end
      elsif record = association
        if !record.new_record? && record.primary_key_value.to_s == id.to_s
          record
        end
      end
    end

    # `update_only` without an ID applies to the current singular association
    # (or the first record for a collection association).
    private def first_nested_{{assoc_name.id}} : {{target_class.id}}?
      association = self.{{assoc_name.id}}
      if association.responds_to?(:all)
        association.all.to_a.first?
      elsif record = association
        record unless record.new_record?
      end
    end

    # Generate save method for this specific association
    private def save_nested_{{assoc_name.id}} : Bool
      attrs_array = _nested_attributes_data[{{ assoc_name.stringify }}]
      return true unless attrs_array
      return true if attrs_array.empty?

      config = {
        allow_destroy: {{ options[:allow_destroy] || false }},
        update_only: {{ options[:update_only] || false }}
      }

      # Get foreign key from association metadata
      foreign_key_name = self.class._{{assoc_name.id}}_association_meta[:foreign_key]
      assoc_type = self.class._{{assoc_name.id}}_association_meta[:type]
      indexed = Grant::AssociationRegistry.reflection(self.class.name, {{ assoc_name.stringify }}).try(&.options["index_errors"]?) == "true"

      success = true
      changed_association = false

      attrs_array.each_with_index do |attr_hash, position|
        prefix = indexed ? "{{ assoc_name.id }}[#{position}]" : "{{ assoc_name.id }}"
        begin
          if config[:allow_destroy] && should_destroy?(attr_hash)
            # Handle destroy
            record = if id = attr_hash["id"]?
                       find_nested_{{assoc_name.id}}_by_id(id)
                     elsif config[:update_only]
                       first_nested_{{assoc_name.id}}
                     end

            if record
                record.mark_for_destruction
                if record.destroy
                  changed_association = true
                else
                  record.errors.each do |error|
                    self.errors << Grant::Error.new("#{prefix}.#{error.field}", error.message)
                  end
                  success = false
                end
            elsif attr_hash.has_key?("id") || config[:update_only]
              self.errors << Grant::Error.new("{{ assoc_name.id }}", "Nested record is not associated with this record")
              success = false
            end
          elsif id = attr_hash["id"]?
            # Handle update
            if record = find_nested_{{assoc_name.id}}_by_id(id)
              # Update attributes
              update_attrs = {} of String => String
              attr_hash.each do |key, value|
                next if key == "id" || key == "_destroy"
                update_attrs[key] = value.to_s
              end

              record.set_attributes(update_attrs)

              if record.changed?
                if record.save
                  changed_association = true
                else
                  record.errors.each do |error|
                    self.errors << Grant::Error.new("#{prefix}.#{error.field}", error.message)
                  end
                  success = false
                end
              end
            else
              self.errors << Grant::Error.new("{{ assoc_name.id }}", "Record with id #{id} is not associated with this record")
              success = false
            end
          elsif config[:update_only] && !@_{{assoc_name.id}}_nested_owner_was_new
            if record = first_nested_{{assoc_name.id}}
              update_attrs = {} of String => String
              attr_hash.each do |key, value|
                next if key == "_destroy"
                update_attrs[key] = value.to_s
              end

              record.set_attributes(update_attrs)

              if record.changed?
                if record.save
                  changed_association = true
                else
                  record.errors.each do |error|
                    self.errors << Grant::Error.new("#{prefix}.#{error.field}", error.message)
                  end
                  success = false
                end
              end
            else
              self.errors << Grant::Error.new("{{ assoc_name.id }}", "Associated record not found for update_only nested attributes")
              success = false
            end
          else
            # Handle create
            record = {{target_class}}.new

            # Set attributes
            create_attrs = {} of String => String
            attr_hash.each do |key, value|
              next if key == "id" || key == "_destroy"
              create_attrs[key] = value.to_s
            end

            record.set_attributes(create_attrs)

            # Set foreign key for has_many/has_one associations
            if (assoc_type == :has_many || assoc_type == :has_one) && self.id
              record.set_attributes({foreign_key_name => self.id.to_s})
            end

            if record.save
              changed_association = true
            else
              record.errors.each do |error|
                self.errors << Grant::Error.new("#{prefix}.#{error.field}", error.message)
              end
              success = false
            end
          end
        rescue ex : Grant::RecordNotFound
          raise ex
        rescue ex
          Log.error { "Error processing nested attributes for {{ assoc_name.id }}: #{ex.message}" }
          self.errors << Grant::Error.new("{{ assoc_name.id }}", ex.message.to_s)
          success = false
        end
      end

      @_{{assoc_name.id}}_nested_existing = nil
      # The cached target no longer matches what was created or destroyed.
      reset_association({{ assoc_name.stringify }}) if changed_association

      success
    end
  end

  # Process single set of attributes with config
  private def process_single_nested_attributes(attrs, config : NamedTuple, rejector : Proc(Hash(String, Grant::Columns::Type), Bool)? = nil) : Hash(String, Grant::Columns::Type)?
    hash_attrs = case attrs
                 when Hash
                   result = {} of String => Grant::Columns::Type
                   attrs.each { |k, v| result[k.to_s] = v }
                   result
                 when NamedTuple
                   result = {} of String => Grant::Columns::Type
                   attrs.each { |k, v| result[k.to_s] = v }
                   result
                 else
                   return
                 end

    # Check reject_if
    if config[:reject_if] == :all_blank
      return if hash_attrs.all? { |k, v| k == "_destroy" || blank_value?(v) }
    end

    if rejector && rejector.call(hash_attrs)
      return
    end

    if config[:update_only] && !hash_attrs.has_key?("id") && !_grant_nested_saves_enabled?
      return
    end

    hash_attrs
  end

  private def blank_value?(value)
    value.nil? || (value.responds_to?(:empty?) && value.empty?)
  end

  private def should_destroy?(attrs : Hash(String, Grant::Columns::Type))
    return false unless val = attrs["_destroy"]?
    case val
    when Bool         then val
    when String       then val == "true" || val == "1"
    when Int32, Int64 then val == 1
    else                   false
    end
  end

  # Get all nested attributes data
  def nested_attributes_data
    _nested_attributes_data
  end
end
