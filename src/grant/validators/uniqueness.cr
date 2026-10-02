module Grant::Validators
  # Validates that a field value is unique in the database.
  #
  # Runs one `SELECT EXISTS` for the value, excluding the record itself when it
  # is already saved. Back the check with a unique index: the validation alone
  # cannot stop two concurrent inserts.
  #
  # Options:
  # - `message:` — custom error message (default: `"has already been taken"`,
  #   type `:taken`)
  # - `scope:` — additional fields that must also match for the record to be
  #   considered a duplicate: a Symbol or an Array of them. A name that is a
  #   `belongs_to` association scopes by its foreign key (and its type column
  #   when polymorphic).
  # - `case_sensitive:` — whether the comparison is case-sensitive
  #   (default: `true`). When `false`, compares `LOWER(column) = LOWER(?)`,
  #   which a plain index cannot serve: on PostgreSQL create a functional
  #   index (`CREATE UNIQUE INDEX ... ON users (LOWER(email))`) or use a
  #   `citext` column; on MySQL use a case-insensitive collation.
  # - `conditions:` — narrows the rows compared. A lambda that takes the
  #   query (and optionally the record) and returns the query:
  #   `->(query : Grant::Query::Builder(Article)) { query.where("deleted_at IS NULL") }`
  # - `allow_nil:` / `allow_blank:`, `if:` / `unless:`, `on:`, `strict:`
  #
  # Column names are quoted for the adapter.
  #
  # ```
  # validates_uniqueness_of :email
  # validates_uniqueness_of :username, case_sensitive: false
  # validates_uniqueness_of :slug, scope: [:category_id]
  # validates_uniqueness_of :slug, scope: :author # the belongs_to association
  # validates_uniqueness_of :email, :username     # validates both fields
  # ```
  macro validates_uniqueness_of(*fields, **options)
    {% message = options[:message] %}
    {% for field in fields %}
      __rule({{field}}, "", :taken, kind: :uniqueness, {{options.double_splat}}) do
        next true if value.nil?

        {% if options[:case_sensitive] == false %}
          query = self.where("LOWER(#{self.quote({{field.id.stringify}})}) = LOWER(?)", value)
        {% else %}
          if self.adapter.mysql?
            query = self.where("BINARY #{self.quote({{field.id.stringify}})} = BINARY ?", value)
          else
            query = self.where({{field.id}}: value)
          end
        {% end %}

        {% if options[:scope] %}
          {% scopes = options[:scope].is_a?(ArrayLiteral) ? options[:scope] : [options[:scope]] %}
          {% for scope_field in scopes %}
            %scope_name = {{scope_field.id.stringify}}
            %reflection = self.reflect_on_association(%scope_name)
            %column = %reflection ? %reflection.foreign_key : %scope_name
            %scope_value = record.__read_validated_attribute(%column)
            if %scope_value.nil?
              query = query.where("#{self.quote(%column)} IS NULL")
            else
              query = query.where("#{self.quote(%column)} = ?", %scope_value)
            end
            if %reflection && (%type_column = %reflection.foreign_type)
              %type_value = record.__read_validated_attribute(%type_column)
              if %type_value.nil?
                query = query.where("#{self.quote(%type_column)} IS NULL")
              else
                query = query.where("#{self.quote(%type_column)} = ?", %type_value)
              end
            end
          {% end %}
        {% end %}

        {% if options[:conditions] %}
          {% conditions = options[:conditions] %}
          {% if conditions.is_a?(ProcLiteral) && conditions.args.size == 2 %}
            query = ({{conditions}}).call(query, record)
          {% else %}
            query = ({{conditions}}).call(query)
          {% end %}
        {% end %}

        # Exclude self if persisted (updating)
        if record.persisted?
          %primary_name = self.primary_name
          if %primary_name && (%primary_value = record.__read_validated_attribute(%primary_name))
            query = query.where("#{self.quote(%primary_name)} != ?", %primary_value)
          end
        end

        next true unless query.exists?
        record.errors.add({{field.id.stringify}}, :taken, message: Grant::Error.wrap_message({{message}}), value: value)
        false
      end
    {% end %}
  end
end
