require "./error"

# Analyze validation blocks and procs
#
# By example:
# ```
# validate :name, "can't be blank" do |user|
#   !user.name.to_s.blank?
# end
#
# validate :name, "can't be blank", ->(user : User) do
#   !user.name.to_s.blank?
# end
#
# name_required = ->(model : Grant::Base) { !model.name.to_s.blank? }
# validate :name, "can't be blank", name_required
# ```
module Grant::Validators
  # Validation context symbols used with `on:` option.
  #
  # - `:create` — runs only when creating a new record
  # - `:update` — runs only when updating an existing record
  # - `:save` — runs on both create and update (default)
  #
  # ```
  # validates_presence_of :name, on: :create
  # validates_presence_of :updated_reason, on: :update
  # ```
  VALID_CONTEXTS = [:create, :update, :save]

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]

  # Returns all errors on the model.
  getter errors = [] of Error

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @_skip_normalization : Bool = false

  macro included
    macro inherited
      @@validators = Array({field: String, message: String, block: Proc(self, Bool), context: Symbol}).new

      # Block-based validate (no context)
      disable_grant_docs? def self.validate(message : String, &block : self -> Bool)
        self.validate(:base, message, block)
      end

      # Block-based validate with field (no context)
      disable_grant_docs? def self.validate(field : (Symbol | String), message : String, &block : self -> Bool)
        self.validate(field, message, block)
      end

      # Proc-based validate (no context)
      disable_grant_docs? def self.validate(message : String, block : self -> Bool)
        self.validate(:base, message, block)
      end

      # Proc-based validate with field (no context)
      disable_grant_docs? def self.validate(field : (Symbol | String), message : String, block : self -> Bool)
        @@validators << {field: field.to_s, message: message, block: block, context: :save}
      end

      # Proc-based validate with context
      disable_grant_docs? def self.validate(field : (Symbol | String), message : String, block : self -> Bool, context : Symbol)
        @@validators << {field: field.to_s, message: message, block: block, context: context}
      end

      # Block-based validate with context keyword
      disable_grant_docs? def self.validate(field : (Symbol | String), message : String, *, context : Symbol = :save, &block : self -> Bool)
        @@validators << {field: field.to_s, message: message, block: block, context: context}
      end

      # ======================================================================
      # Built-in Validators
      #
      # These macros are defined inside `macro inherited` so that they are
      # available in every Grant::Base subclass, even when individual spec
      # files are compiled standalone.
      #
      # All validators use block syntax (`do |record| ... end`) instead of
      # arrow proc syntax (`->(record : self) { ... }`) so that `next` works
      # inside `if` blocks within the validator body.
      # ======================================================================

      # Validates that a field is present (not nil, not blank, not empty).
      #
      # For strings, checks that the value is not nil and not blank (whitespace-only).
      # For arrays, checks that the value is not nil and not empty.
      # For all other types, checks that the value is not nil.
      #
      # Supports the following options:
      # - `message:` — custom error message (default: `"can't be blank"`)
      # - `if:` — method symbol; only validate when truthy
      # - `unless:` — method symbol; skip validation when truthy
      # - `allow_nil:` — skip validation if the value is nil
      # - `on:` — validation context (`:create`, `:update`, or `:save`)
      #
      # ```
      # validates_presence_of :name
      # validates_presence_of :email, message: "is required"
      # validates_presence_of :terms_accepted, on: :create
      # validates_presence_of :reason, on: :update, if: :requires_reason?
      # ```
      macro validates_presence_of(field, **options)
        \\{% message = options[:message] || "can't be blank" %}
        \\{% context = options[:on] || :save %}

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% end %}
          \\{% end %}

          \\{% if options[:allow_nil] %}
            next true if record.\\{{field.id}}.nil?
          \\{% end %}

          value = record.\\{{field.id}}

          case value
          when Nil
            false
          when String
            !value.blank?
          when Array
            !value.empty?
          else
            true
          end
        end
      end

      # Validates that a field value is unique in the database.
      #
      # Queries the database to check that no other record has the same value
      # for the specified field. When updating an existing record, excludes
      # the current record from the check.
      #
      # Supports the following options:
      # - `message:` — custom error message (default: `"has already been taken"`)
      # - `scope:` — additional fields that must also match for the record to
      #   be considered a duplicate. Accepts an array of symbols.
      # - `case_sensitive:` — whether the comparison is case-sensitive
      #   (default: `true`). When `false`, uses SQL `LOWER()` function.
      # - `allow_nil:` — skip validation if the value is nil
      # - `allow_blank:` — skip validation if the value is nil or blank
      # - `if:` / `unless:` — conditional validation
      # - `on:` — validation context (`:create`, `:update`, or `:save`)
      #
      # ```
      # validates_uniqueness_of :email
      # validates_uniqueness_of :username, case_sensitive: false
      # validates_uniqueness_of :slug, scope: [:category_id]
      # validates_uniqueness_of :code, scope: [:region, :year], message: "is already used"
      # ```
      macro validates_uniqueness_of(field, **options)
        \\{% message = options[:message] || "has already been taken" %}
        \\{% context = options[:on] || :save %}

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% end %}
          \\{% end %}

          value = record.\\{{field.id}}

          \\{% if options[:allow_nil] %}
            next true if value.nil?
          \\{% elsif options[:allow_blank] %}
            next true if value.nil? || value.to_s.blank?
          \\{% end %}

          next true if value.nil?

          # Build the base query
          \\{% if options[:case_sensitive] == false %}
            _field_name = \\{{field.id.stringify}}
            query = self.where("LOWER(#{_field_name}) = LOWER(?)", value)
          \\{% else %}
            query = self.where(\\{{field.id}}: value)
          \\{% end %}

          # Add scope conditions
          \\{% if options[:scope] %}
            \\{% for scope_field in options[:scope] %}
              scope_value = record.\\{{scope_field.id}}
              query = query.where(\\{{scope_field.id}}: scope_value)
            \\{% end %}
          \\{% end %}

          # Exclude self if persisted (updating)
          if record.persisted?
            pk = record.to_h[self.primary_name]?
            if pk
              query = query.where("#{self.primary_name} != ?", pk)
            end
          end

          !query.exists?
        end
      end

      # Validates that a numeric field meets specified criteria.
      #
      # Supports the following constraints:
      # - `greater_than:` — value must be greater than the given number
      # - `greater_than_or_equal_to:` — value must be >= the given number
      # - `less_than:` — value must be less than the given number
      # - `less_than_or_equal_to:` — value must be <= the given number
      # - `equal_to:` — value must equal the given number
      # - `other_than:` — value must not equal the given number
      # - `odd:` — value must be odd
      # - `even:` — value must be even
      # - `only_integer:` — value must be an integer
      # - `in:` — value must be in the given range or collection
      # - `message:` — custom error message
      # - `allow_nil:` — skip validation if the value is nil
      # - `allow_blank:` — skip validation if the value is nil or blank
      # - `if:` / `unless:` — conditional validation
      # - `on:` — validation context
      #
      # ```
      # validates_numericality_of :price, greater_than: 0
      # validates_numericality_of :quantity, only_integer: true
      # validates_numericality_of :score, in: 1..10
      # ```
      macro validates_numericality_of(field, **options)
        \\{%
          message_base = options[:message] || "is not a number"
          conditions = [] of String

          if gt = options[:greater_than]
            conditions << "greater than " + gt.stringify
          end
          if gte = options[:greater_than_or_equal_to]
            conditions << "greater than or equal to " + gte.stringify
          end
          if lt = options[:less_than]
            conditions << "less than " + lt.stringify
          end
          if lte = options[:less_than_or_equal_to]
            conditions << "less than or equal to " + lte.stringify
          end
          if eq = options[:equal_to]
            conditions << "equal to " + eq.stringify
          end
          if other = options[:other_than]
            conditions << "other than " + other.stringify
          end
          if options[:odd]
            conditions << "odd"
          end
          if options[:even]
            conditions << "even"
          end
          if options[:only_integer]
            conditions << "an integer"
          end

          full_message = conditions.empty? ? message_base : ("must be " + conditions.join(" and "))
          context = options[:on] || :save
        %}

        validate(\\{{field}}, \\{{full_message}}, context: \\{{context}}) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% end %}
          \\{% end %}

          value = record.\\{{field.id}}

          # Allow nil if specified
          \\{% if options[:allow_nil] %}
            next true if value.nil?
          \\{% elsif options[:allow_blank] %}
            next true if value.nil? || value.to_s.blank?
          \\{% end %}

          # Ensure it's numeric
          next false unless value.is_a?(Number)

          # Check specific validations
          \\{% if options[:greater_than] %}
            next false unless value > \\{{options[:greater_than]}}
          \\{% end %}
          \\{% if options[:greater_than_or_equal_to] %}
            next false unless value >= \\{{options[:greater_than_or_equal_to]}}
          \\{% end %}
          \\{% if options[:less_than] %}
            next false unless value < \\{{options[:less_than]}}
          \\{% end %}
          \\{% if options[:less_than_or_equal_to] %}
            next false unless value <= \\{{options[:less_than_or_equal_to]}}
          \\{% end %}
          \\{% if options[:equal_to] %}
            next false unless value == \\{{options[:equal_to]}}
          \\{% end %}
          \\{% if options[:other_than] %}
            next false unless value != \\{{options[:other_than]}}
          \\{% end %}
          \\{% if options[:odd] %}
            next false unless value.to_i.odd?
          \\{% end %}
          \\{% if options[:even] %}
            next false unless value.to_i.even?
          \\{% end %}
          \\{% if options[:in] %}
            next false unless (\\{{options[:in]}}).includes?(value)
          \\{% end %}
          \\{% if options[:only_integer] %}
            next false unless value == value.to_i
          \\{% end %}

          true
        end
      end

      # Validates format using regular expressions.
      #
      # Supports the following options:
      # - `with:` — a Regex that the value must match
      # - `without:` — a Regex that the value must NOT match
      # - `message:` — custom error message (default: `"is invalid"`)
      # - `allow_nil:` — skip validation if the value is nil
      # - `allow_blank:` — skip if nil or blank
      # - `if:` / `unless:` — conditional validation
      # - `on:` — validation context
      #
      # ```
      # validates_format_of :phone, with: /\A\d{3}-\d{3}-\d{4}\z/
      # validates_format_of :username, without: /\A(admin|root)\z/, message: "is reserved"
      # ```
      macro validates_format_of(field, **options)
        \\{%
          with_pattern = options[:with]
          without_pattern = options[:without]
          message = options[:message] || "is invalid"
          context = options[:on] || :save
        %}

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% end %}
          \\{% end %}

          value = record.\\{{field.id}}

          \\{% if options[:allow_nil] %}
            next true if value.nil?
          \\{% elsif options[:allow_blank] %}
            next true if value.nil? || value.to_s.blank?
          \\{% end %}

          string_value = value.to_s

          \\{% if with_pattern %}
            next false unless string_value.matches?(\\{{with_pattern}})
          \\{% end %}
          \\{% if without_pattern %}
            next false if string_value.matches?(\\{{without_pattern}})
          \\{% end %}

          true
        end
      end

      # Validates the length of a string or array field.
      #
      # Supports the following options:
      # - `minimum:` — minimum length required
      # - `maximum:` — maximum length allowed
      # - `is:` — exact length required
      # - `in:` — a range of acceptable lengths
      # - `message:` — custom error message
      # - `allow_nil:` — skip validation if the value is nil
      # - `allow_blank:` — skip if nil or empty
      # - `if:` / `unless:` — conditional validation
      # - `on:` — validation context
      #
      # ```
      # validates_length_of :name, minimum: 2, maximum: 50
      # validates_length_of :code, is: 4
      # validates_length_of :password, in: 8..128
      # ```
      macro validates_length_of(field, **options)
        \\{%
          conditions = [] of String

          if min = options[:minimum]
            conditions << "at least " + min.stringify + " characters"
          end
          if max = options[:maximum]
            conditions << "at most " + max.stringify + " characters"
          end
          if exact = options[:is]
            conditions << "exactly " + exact.stringify + " characters"
          end
          if range = options[:in]
            conditions << "between " + range.begin.stringify + " and " + range.end.stringify + " characters"
          end

          message = options[:message] || (conditions.empty? ? "has incorrect length" : ("must be " + conditions.join(" and ")))
          context = options[:on] || :save
        %}

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% end %}
          \\{% end %}

          value = record.\\{{field.id}}

          \\{% if options[:allow_nil] %}
            next true if value.nil?
          \\{% elsif options[:allow_blank] %}
            next true if value.nil? || (value.responds_to?(:empty?) && value.empty?)
          \\{% end %}

          length = if value.responds_to?(:size)
            value.size
          else
            value.to_s.size
          end

          \\{% if options[:minimum] %}
            next false if length < \\{{options[:minimum]}}
          \\{% end %}
          \\{% if options[:maximum] %}
            next false if length > \\{{options[:maximum]}}
          \\{% end %}
          \\{% if options[:is] %}
            next false unless length == \\{{options[:is]}}
          \\{% end %}
          \\{% if options[:in] %}
            next false unless (\\{{options[:in]}}).includes?(length)
          \\{% end %}

          true
        end
      end

      # Alias for `validates_length_of`.
      macro validates_size_of(field, **options)
        validates_length_of(\\{{field}}, \\{{**options}})
      end

      # Validates that a confirmation field matches the original field.
      #
      # Creates a virtual `property` for the confirmation attribute
      # (e.g., `email_confirmation` for `validates_confirmation_of :email`).
      #
      # ```
      # validates_confirmation_of :email
      # validates_confirmation_of :password, message: "passwords don't match"
      # ```
      macro validates_confirmation_of(field, **options)
        \\{%
          message = options[:message] || "doesn't match confirmation"
          confirmation_field = (field.stringify + "_confirmation").id
          context = options[:on] || :save
        %}

        # Create virtual attribute for confirmation
        property \\{{confirmation_field}} : String?

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% end %}
          \\{% end %}

          confirmation_value = record.\\{{confirmation_field}}
          next true if confirmation_value.nil?

          record.\\{{field.id}}.to_s == confirmation_value
        end
      end

      # Validates acceptance of terms or conditions.
      #
      # Creates a virtual attribute if one doesn't already exist.
      # Checks that the value is one of the accepted values.
      #
      # ```
      # validates_acceptance_of :terms_of_service
      # validates_acceptance_of :eula, accept: ["yes", "1"]
      # ```
      macro validates_acceptance_of(field, **options)
        \\{%
          message = options[:message] || "must be accepted"
          accept_values = options[:accept] || ["1", "true", "yes", "on"]
          context = options[:on] || :save
        %}

        # Create virtual attribute if it doesn't exist
        \\{% unless @type.instance_vars.any? { |ivar| ivar.name == field.id } %}
          property \\{{field}} : String?
        \\{% end %}

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% end %}
          \\{% end %}

          value = record.\\{{field.id}}

          case value
          when Nil
            \\{% unless options[:allow_nil] %}
              false
            \\{% else %}
              true
            \\{% end %}
          when Bool
            value == true
          else
            \\{{accept_values}}.includes?(value.to_s.downcase)
          end
        end
      end

      # Validates that associated records are also valid.
      #
      # ```
      # validates_associated :items
      # validates_associated :profile, :address
      # ```
      macro validates_associated(*associations, **options)
        \\{% context = options[:on] || :save %}
        \\{% for association in associations %}
          \\{% message = options[:message] || "is invalid" %}

          validate(\\{{association}}, \\{{message}}, context: \\{{context}}) do |record|
            \\{% if options[:if] %}
              \\{% if options[:if].is_a?(SymbolLiteral) %}
                if record.responds_to?(\\{{options[:if]}})
                  next true unless record.\\{{options[:if].id}}
                end
              \\{% end %}
            \\{% end %}
            \\{% if options[:unless] %}
              \\{% if options[:unless].is_a?(SymbolLiteral) %}
                if record.responds_to?(\\{{options[:unless]}})
                  next true if record.\\{{options[:unless].id}}
                end
              \\{% end %}
            \\{% end %}

            associated = record.\\{{association.id}}

            case associated
            when Nil
              true
            when Array
              associated.all? { |item| item.valid? }
            else
              associated.valid?
            end
          end
        \\{% end %}
      end

      # Validates that a value is included in a given set.
      #
      # ```
      # validates_inclusion_of :status, in: ["active", "inactive"]
      # validates_inclusion_of :role, in: ["admin", "user", "guest"]
      # ```
      macro validates_inclusion_of(field, **options)
        \\{%
          in_values = options[:in]
          message = options[:message] || "is not included in the list"
          context = options[:on] || :save
        %}

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% end %}
          \\{% end %}

          value = record.\\{{field.id}}

          \\{% if options[:allow_nil] %}
            next true if value.nil?
          \\{% elsif options[:allow_blank] %}
            next true if value.nil? || value.to_s.blank?
          \\{% end %}

          (\\{{in_values}}).includes?(value)
        end
      end

      # Validates that a value is NOT in a given set.
      #
      # ```
      # validates_exclusion_of :username, in: ["admin", "root", "superuser"]
      # ```
      macro validates_exclusion_of(field, **options)
        \\{%
          in_values = options[:in]
          message = options[:message] || "is reserved"
          context = options[:on] || :save
        %}

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% end %}
          \\{% end %}

          value = record.\\{{field.id}}

          \\{% if options[:allow_nil] %}
            next true if value.nil?
          \\{% elsif options[:allow_blank] %}
            next true if value.nil? || value.to_s.blank?
          \\{% end %}

          !(\\{{in_values}}).includes?(value)
        end
      end

      # Validates that a field is a valid email address.
      #
      # Uses the `EMAIL_REGEX` pattern from `Grant::Validators::BuiltIn::CommonFormats`.
      #
      # ```
      # validates_email :email
      # validates_email :contact_email, message: "must be a valid email"
      # ```
      macro validates_email(field, **options)
        \\{% email_message = options[:message] || "is not a valid email" %}
        \\{% email_context = options[:on] || :save %}
        validates_format_of(\\{{field}}, with: Grant::Validators::BuiltIn::CommonFormats::EMAIL_REGEX, message: \\{{email_message}}, on: \\{{email_context}})
      end

      # Validates that a field is a valid URL.
      #
      # Uses the `URL_REGEX` pattern from `Grant::Validators::BuiltIn::CommonFormats`.
      #
      # ```
      # validates_url :website
      # validates_url :homepage, message: "must be a valid URL"
      # ```
      macro validates_url(field, **options)
        \\{% url_message = options[:message] || "is not a valid URL" %}
        \\{% url_context = options[:on] || :save %}
        validates_format_of(\\{{field}}, with: Grant::Validators::BuiltIn::CommonFormats::URL_REGEX, message: \\{{url_message}}, on: \\{{url_context}})
      end
    end
  end

  # Runs all of `self`'s validators, returning `true` if they all pass, and `false`
  # otherwise.
  #
  # If the validation fails, `#errors` will contain all the errors responsible for
  # the failing.
  #
  # An optional `context` parameter can be passed to filter validators by context.
  # When `context` is `:create`, only validators with `context: :create` or `context: :save` run.
  # When `context` is `:update`, only validators with `context: :update` or `context: :save` run.
  # When `context` is nil or `:save`, all validators run.
  #
  # ```
  # record.valid?                    # runs all validators
  # record.valid?(context: :create)  # runs :create and :save validators
  # record.valid?(context: :update)  # runs :update and :save validators
  # ```
  def valid?(skip_normalization : Bool = false, context : Symbol? = nil)
    # Return false if any `ConversionError` were added
    # when setting model properties
    return false if errors.any? ConversionError

    errors.clear

    # Set flag for normalization to check
    @_skip_normalization = skip_normalization

    # Run before_validation callbacks
    before_validation if responds_to?(:before_validation)

    @@validators.each do |validator|
      # Filter by context when specified
      if context
        validator_context = validator[:context]
        # :save validators always run; otherwise context must match
        next unless validator_context == :save || validator_context == context
      end

      unless validator[:block].call(self)
        errors << Error.new(validator[:field], validator[:message])
      end
    end

    # Run after_validation callbacks
    after_validation if responds_to?(:after_validation)

    # Reset the flag
    @_skip_normalization = false

    errors.empty?
  end
end
