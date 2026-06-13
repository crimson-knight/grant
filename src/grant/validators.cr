require "./error"
require "./errors"

# Base class for reusable, object-oriented validators registered via
# `validates_with` (AR-compatible).
#
# Subclass and implement `#validate(record)`, adding errors directly to
# `record.errors`. A new instance is created for each validation run, so any
# configuration should be passed through the constructor and forwarded by
# `validates_with`.
#
# ```
# class TotalsValidator < Grant::Validator
#   def validate(record)
#     if record.discount > record.total
#       record.errors.add(:discount, "exceeds total", type: :greater_than)
#     end
#   end
# end
#
# class Invoice < Grant::Base
#   validates_with TotalsValidator
# end
# ```
abstract class Grant::Validator
  # Performs validation against the given record, adding any errors to
  # `record.errors`. The record is typed as `Grant::Base` for the base
  # signature; subclasses may downcast as needed.
  abstract def validate(record)
end

# Base class for attribute-scoped reusable validators registered via
# `validates_each ..., with: MyValidator` (AR's `EachValidator` analogue).
#
# Subclass and implement `#validate_each(record, attribute, value)`. The
# default `#validate` is provided for use with `validates_with` when an
# `attributes` list is supplied to the constructor.
#
# ```
# class PresenceEachValidator < Grant::EachValidator
#   def validate_each(record, attribute, value)
#     record.errors.add(attribute, "can't be blank", type: :blank) if value.nil?
#   end
# end
# ```
abstract class Grant::EachValidator < Grant::Validator
  # Attributes this validator was configured for (used by `validate`).
  getter attributes : Array(String)

  def initialize(*attributes : String | Symbol)
    @attributes = attributes.map(&.to_s).to_a
  end

  def initialize(attributes : Enumerable(String | Symbol) = [] of String)
    @attributes = attributes.map(&.to_s).to_a
  end

  # Runs `validate_each` for each configured attribute. Subclasses normally
  # use this through `validates_with PresenceEachValidator, :a, :b`.
  def validate(record)
    @attributes.each do |attribute|
      validate_each(record, attribute, record_attribute(record, attribute))
    end
  end

  # Override `validate_each` in subclasses.
  abstract def validate_each(record, attribute, value)

  # Best-effort attribute read; returns the value from the record's `to_h`
  # snapshot so it works without per-attribute compile-time dispatch.
  private def record_attribute(record, attribute)
    record.responds_to?(:to_h) ? record.to_h[attribute]? : nil
  end
end

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

  # Backing store for the errors collection. Declared nilable (with lazy
  # initialization in the `errors` getter below) rather than carrying a
  # default value so that `YAML::Serializable` / `JSON::Serializable`'s
  # auto-generated deserialization initializer — included on the abstract
  # `Grant::Base` — does not report it as uninitialized for `Grant::Base+`.
  # The annotations keep the transient errors collection out of (de)serialized
  # output. See issues #39/#41.
  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @errors : Errors?

  # Returns all errors on the model.
  #
  # The errors collection provides a rich API for working with
  # validation errors. See `Grant::Errors` for the full API.
  #
  # ```
  # record.errors.any?          # => true/false
  # record.errors[:name]        # => ["can't be blank"]
  # record.errors.full_messages # => ["Name can't be blank"]
  # record.errors.add(:base, "Something went wrong")
  # ```
  def errors : Errors
    @errors ||= Errors.new
  end

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @_skip_normalization : Bool?

  macro included
    macro inherited
      # `@@validators` is declared on EVERY level so each concrete class
      # (including multi-level STI subclasses) can read it in `valid?`. Crystal
      # class variables are per-class, and re-declaring with a different element
      # type than an ancestor is a compile error, so the Proc's argument is typed
      # to the *first-level* ancestor (the class directly below `Grant::Base`)
      # rather than to `self`. The `self.validate` overloads / `validate_method`
      # / `validate` macros are defined only at the first level (where `self` ==
      # that ancestor) and inherited — see the first-level guard below. Macro
      # control flow nested in `macro included` is escaped with a leading
      # backslash so it evaluates at each subclass's `inherited` expansion.
      #
      # NOTE (STI limitation): class vars are per-class, so a base class's
      # `validate` registrations populate only the base class's store and don't
      # auto-run on STI subclass instances; and subclass-specific
      # `validate`/`validates_*` blocks see `record` typed as the first-level
      # ancestor, so reference base columns or use `before_validation`.
      \{% candidates = [@type] + @type.ancestors %}
      \{% first_level = candidates.find { |a| a.class? && a.superclass && a.superclass.id == "Grant::Base" } %}
      \{% first_level = @type if first_level == nil %}
      @@validators = Array({field: String, message: String, block: Proc(\{{ first_level }}, Bool), context: Symbol, code: Symbol?}).new

      \{% if @type.superclass.id == "Grant::Base" %}
      # Low-level registration helper used by both the `self.validate` method
      # overloads and the bare-Symbol `validate :method_name` macro form.
      disable_grant_docs? def self.__add_validator(field : (Symbol | String), message : String, block : self -> Bool, context : Symbol = :save, code : Symbol? = nil)
        @@validators << {field: field.to_s, message: message, block: block, context: context, code: code}
      end

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
      disable_grant_docs? def self.validate(field : (Symbol | String), message : String, block : self -> Bool, code : Symbol? = nil)
        @@validators << {field: field.to_s, message: message, block: block, context: :save, code: code}
      end

      # Proc-based validate with context
      disable_grant_docs? def self.validate(field : (Symbol | String), message : String, block : self -> Bool, context : Symbol, code : Symbol? = nil)
        @@validators << {field: field.to_s, message: message, block: block, context: context, code: code}
      end

      # Block-based validate with context keyword (and optional error code)
      disable_grant_docs? def self.validate(field : (Symbol | String), message : String, *, context : Symbol = :save, code : Symbol? = nil, &block : self -> Bool)
        @@validators << {field: field.to_s, message: message, block: block, context: context, code: code}
      end

      # Registers an instance method that performs its own validation and adds
      # errors directly (AR-compatible `validate :method_name`).
      #
      # The named method runs during the validation phase and records its own
      # errors via `errors.add(...)`. Supports `on:` (context) and `if:`/
      # `unless:` (Symbol method name **or** Proc/lambda) conditions.
      #
      # ```
      # validate_method :discount_cannot_exceed_total
      # validate_method :title_present, on: :create, if: :published?
      #
      # private def discount_cannot_exceed_total
      #   errors.add(:discount, "exceeds total", type: :greater_than) if discount > total
      # end
      # ```
      #
      # This is exposed both directly and via the `validate :method_name`
      # macro form below (which dispatches here at compile time). A runtime
      # Symbol cannot be dispatched to a named method in Crystal, so the method
      # name must be resolved at compile time.
      macro validate_method(method_name, **options)
        \\{% context = options[:on] || :save %}

        # Generate a public wrapper so the referenced method may be `private`
        # (the common AR pattern). The validator block runs with the record as
        # an explicit receiver, and Crystal forbids calling private methods on
        # an explicit receiver — so we route through this wrapper, which calls
        # the target from instance context where private access is allowed.
        disable_grant_docs? def __run_validate_\\{{method_name.id}}
          \\{{method_name.id}}
        end

        # Snapshot error count before running the user method; the validator
        # "fails" (driving valid? false) only if the method added errors. The
        # placeholder entry carries a blank `:base` message that is never shown
        # because the validator block returns true on success.
        validate(:base, "", context: \\{{context}}) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% else %}
              next true unless (\\{{options[:if]}}).call(record)
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% else %}
              next true if (\\{{options[:unless]}}).call(record)
            \\{% end %}
          \\{% end %}

          %before = record.errors.size
          record.__run_validate_\\{{method_name.id}}
          record.errors.size == %before
        end
      end

      # Single-positional-argument `validate` entry point.
      #
      # This macro overload coexists with the multi-argument
      # `self.validate(field, message, ...)` methods — Crystal dispatches
      # `validate :foo` / `validate "msg" do ... end` (one positional arg) to
      # this macro and `validate :field, "msg", ...` (two+ positional args) to
      # the methods, by arity.
      #
      # Two one-arg shapes are supported here:
      #   * `validate "message" do |record| ... end` — the classic base-field
      #     block form; forwarded to the `self.validate(message, &block)` method.
      #   * `validate :method_name` — AR-compatible reference to an instance
      #     method that records its own errors; forwarded to `validate_method`.
      #
      # ```
      # validate :ensure_consistency
      # validate :ensure_consistency, on: :update, unless: :skip_checks?
      # validate "name can't be blank" { |r| !r.name.to_s.blank? }
      # ```
      macro validate(name_or_method, **options, &block)
        \\{% if block.is_a?(Block) %}
          # Classic base-field block form — preserve existing behavior by
          # forwarding to the method overload.
          self.validate(\\{{name_or_method}}) do \\{{ "|#{block.args.splat}|".id }}
            \\{{block.body}}
          end
        \\{% else %}
          validate_method(\\{{name_or_method}}, \\{{**options}})
        \\{% end %}
      end
      \{% end %}

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

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}, code: :blank) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% else %}
              next true unless (\\{{options[:if]}}).call(record)
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% else %}
              next true if (\\{{options[:unless]}}).call(record)
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

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}, code: :taken) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% else %}
              next true unless (\\{{options[:if]}}).call(record)
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% else %}
              next true if (\\{{options[:unless]}}).call(record)
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

          # Pick the most specific AR-style code: a single constraint maps to
          # its own code; multiple (or none) fall back to :not_a_number.
          num_code = :not_a_number
          if options[:greater_than]
            num_code = :greater_than
          elsif options[:greater_than_or_equal_to]
            num_code = :greater_than_or_equal_to
          elsif options[:less_than]
            num_code = :less_than
          elsif options[:less_than_or_equal_to]
            num_code = :less_than_or_equal_to
          elsif options[:equal_to]
            num_code = :equal_to
          elsif options[:other_than]
            num_code = :other_than
          elsif options[:odd]
            num_code = :odd
          elsif options[:even]
            num_code = :even
          elsif options[:only_integer]
            num_code = :not_an_integer
          end
        %}

        validate(\\{{field}}, \\{{full_message}}, context: \\{{context}}, code: \\{{num_code}}) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% else %}
              next true unless (\\{{options[:if]}}).call(record)
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% else %}
              next true if (\\{{options[:unless]}}).call(record)
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

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}, code: :invalid) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% else %}
              next true unless (\\{{options[:if]}}).call(record)
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% else %}
              next true if (\\{{options[:unless]}}).call(record)
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

          # Most-specific AR length code when a single bound is given.
          len_code = :wrong_length
          if options[:minimum] && !options[:maximum] && !options[:is] && !options[:in]
            len_code = :too_short
          elsif options[:maximum] && !options[:minimum] && !options[:is] && !options[:in]
            len_code = :too_long
          elsif options[:is]
            len_code = :wrong_length
          end
        %}

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}, code: \\{{len_code}}) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% else %}
              next true unless (\\{{options[:if]}}).call(record)
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% else %}
              next true if (\\{{options[:unless]}}).call(record)
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

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}, code: :confirmation) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% else %}
              next true unless (\\{{options[:if]}}).call(record)
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% else %}
              next true if (\\{{options[:unless]}}).call(record)
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

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}, code: :accepted) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% else %}
              next true unless (\\{{options[:if]}}).call(record)
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% else %}
              next true if (\\{{options[:unless]}}).call(record)
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

          validate(\\{{association}}, \\{{message}}, context: \\{{context}}, code: :invalid) do |record|
            \\{% if options[:if] %}
              \\{% if options[:if].is_a?(SymbolLiteral) %}
                if record.responds_to?(\\{{options[:if]}})
                  next true unless record.\\{{options[:if].id}}
                end
              \\{% else %}
                next true unless (\\{{options[:if]}}).call(record)
              \\{% end %}
            \\{% end %}
            \\{% if options[:unless] %}
              \\{% if options[:unless].is_a?(SymbolLiteral) %}
                if record.responds_to?(\\{{options[:unless]}})
                  next true if record.\\{{options[:unless].id}}
                end
              \\{% else %}
                next true if (\\{{options[:unless]}}).call(record)
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

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}, code: :inclusion) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% else %}
              next true unless (\\{{options[:if]}}).call(record)
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% else %}
              next true if (\\{{options[:unless]}}).call(record)
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

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}, code: :exclusion) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% else %}
              next true unless (\\{{options[:if]}}).call(record)
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% else %}
              next true if (\\{{options[:unless]}}).call(record)
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

      # Validates that a field is absent (the inverse of presence).
      #
      # A field is considered absent when it is `nil`, a blank/whitespace-only
      # `String`, or an empty `Array`. All other values fail.
      #
      # Supports the following options:
      # - `message:` — custom error message (default: `"must be blank"`)
      # - `if:` / `unless:` — Symbol method name or Proc/lambda condition
      # - `on:` — validation context (`:create`, `:update`, or `:save`)
      #
      # ```
      # validates_absence_of :legacy_token
      # validates_absence_of :nickname, on: :create
      # ```
      macro validates_absence_of(field, **options)
        \\{% message = options[:message] || "must be blank" %}
        \\{% context = options[:on] || :save %}

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}, code: :present) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% else %}
              next true unless (\\{{options[:if]}}).call(record)
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% else %}
              next true if (\\{{options[:unless]}}).call(record)
            \\{% end %}
          \\{% end %}

          value = record.\\{{field.id}}

          case value
          when Nil
            true
          when String
            value.blank?
          when Array
            value.empty?
          else
            false
          end
        end
      end

      # Validates a field by comparing it to another value (AR 7.1+).
      #
      # Supports the following comparison options (provide exactly one or more):
      # - `greater_than:` — value must be `>` the operand
      # - `greater_than_or_equal_to:` — value must be `>=` the operand
      # - `equal_to:` — value must be `==` the operand
      # - `less_than:` — value must be `<` the operand
      # - `less_than_or_equal_to:` — value must be `<=` the operand
      # - `other_than:` — value must be `!=` the operand
      #
      # Each operand may be a literal, or a Symbol naming an instance method
      # (the method is invoked on the record to obtain the comparison value),
      # enabling comparisons like `started_at < ended_at`.
      #
      # Other options:
      # - `message:` — custom error message (default: `"failed comparison"`)
      # - `allow_nil:` — skip when the field value is nil
      # - `if:` / `unless:` — Symbol method name or Proc/lambda condition
      # - `on:` — validation context
      #
      # ```
      # validates_comparison_of :age, greater_than_or_equal_to: 18
      # validates_comparison_of :ended_at, greater_than: :started_at
      # validates_comparison_of :status, other_than: "archived"
      # ```
      macro validates_comparison_of(field, **options)
        \\{%
          context = options[:on] || :save

          comparisons = [] of Nil
          if options[:greater_than] != nil
            comparisons << {op: ">", operand: options[:greater_than], desc: "greater than"}
          end
          if options[:greater_than_or_equal_to] != nil
            comparisons << {op: ">=", operand: options[:greater_than_or_equal_to], desc: "greater than or equal to"}
          end
          if options[:equal_to] != nil
            comparisons << {op: "==", operand: options[:equal_to], desc: "equal to"}
          end
          if options[:less_than] != nil
            comparisons << {op: "<", operand: options[:less_than], desc: "less than"}
          end
          if options[:less_than_or_equal_to] != nil
            comparisons << {op: "<=", operand: options[:less_than_or_equal_to], desc: "less than or equal to"}
          end
          if options[:other_than] != nil
            comparisons << {op: "!=", operand: options[:other_than], desc: "other than"}
          end

          descs = comparisons.map { |c| c[:desc] }
          message = options[:message] || ("must be " + descs.join(" and "))
        %}

        validate(\\{{field}}, \\{{message}}, context: \\{{context}}, code: :comparison) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% else %}
              next true unless (\\{{options[:if]}}).call(record)
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% else %}
              next true if (\\{{options[:unless]}}).call(record)
            \\{% end %}
          \\{% end %}

          value = record.\\{{field.id}}

          \\{% if options[:allow_nil] %}
            next true if value.nil?
          \\{% end %}

          # nil cannot be meaningfully compared; AR treats it as a failure.
          next false if value.nil?

          \\{% for c in comparisons %}
            \\{% operand = c[:operand] %}
            # A Symbol operand names an instance method to read at runtime;
            # any other operand is used as a literal value.
            \\{% if operand.is_a?(SymbolLiteral) %}
              %operand = record.\\{{operand.id}}
            \\{% else %}
              %operand = \\{{operand}}
            \\{% end %}
            next false if %operand.nil?
            next false unless value.not_nil! \\{{c[:op].id}} %operand.not_nil!
          \\{% end %}

          true
        end
      end

      # Registers a reusable validator object (AR-compatible `validates_with`).
      #
      # The validator class must define an instance method
      # `validate(record)` that performs checks and adds errors to
      # `record.errors`. A fresh instance is created per validation run, so
      # validators should be stateless (or accept configuration through
      # constructor arguments forwarded here).
      #
      # ```
      # class EvenValidator < Grant::EachValidator
      #   def validate(record)
      #     record.errors.add(:value, "must be even", type: :even) if record.value.odd?
      #   end
      # end
      #
      # class Counter < Grant::Base
      #   validates_with EvenValidator
      # end
      # ```
      #
      # Extra positional/keyword args are forwarded to the validator's
      # constructor, mirroring AR's `validates_with MyValidator, option: 1`.
      macro validates_with(validator_class, *args, **options)
        \\{% context = options[:on] || :save %}
        validate(:base, "", context: \\{{context}}) do |record|
          \\{% if options[:if] %}
            \\{% if options[:if].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:if]}})
                next true unless record.\\{{options[:if].id}}
              end
            \\{% else %}
              next true unless (\\{{options[:if]}}).call(record)
            \\{% end %}
          \\{% end %}
          \\{% if options[:unless] %}
            \\{% if options[:unless].is_a?(SymbolLiteral) %}
              if record.responds_to?(\\{{options[:unless]}})
                next true if record.\\{{options[:unless].id}}
              end
            \\{% else %}
              next true if (\\{{options[:unless]}}).call(record)
            \\{% end %}
          \\{% end %}

          %before = record.errors.size
          # `on:`/`if:`/`unless:` are consumed here and not forwarded to the
          # validator's constructor.
          %validator = \\{{validator_class}}.new(\\{% for a in args %}\\{{a}}, \\{% end %}\\{% for k, v in options %}\\{% unless k == :on || k == :if || k == :unless %}\\{{k}}: \\{{v}}, \\{% end %}\\{% end %})
          %validator.validate(record)
          record.errors.size == %before
        end
      end

      # Convenience for attribute-scoped reusable validators. Registers a
      # `Grant::EachValidator` subclass against one or more attributes; the
      # validator's `validate_each(record, attribute, value)` runs once per
      # attribute. Mirrors AR's `validates :attr, my: {...}` ergonomics in a
      # simpler form.
      #
      # ```
      # validates_each :email, :name, with: PresenceEachValidator
      # ```
      macro validates_each(*attributes, **options)
        \\{% validator_class = options[:with] %}
        \\{% context = options[:on] || :save %}
        \\{% raise "validates_each requires `with:` naming an EachValidator subclass" unless validator_class %}
        \\{% for attribute in attributes %}
          validate(\\{{attribute}}, "", context: \\{{context}}) do |record|
            \\{% if options[:if] %}
              \\{% if options[:if].is_a?(SymbolLiteral) %}
                if record.responds_to?(\\{{options[:if]}})
                  next true unless record.\\{{options[:if].id}}
                end
              \\{% else %}
                next true unless (\\{{options[:if]}}).call(record)
              \\{% end %}
            \\{% end %}
            \\{% if options[:unless] %}
              \\{% if options[:unless].is_a?(SymbolLiteral) %}
                if record.responds_to?(\\{{options[:unless]}})
                  next true if record.\\{{options[:unless].id}}
                end
              \\{% else %}
                next true if (\\{{options[:unless]}}).call(record)
              \\{% end %}
            \\{% end %}

            %before = record.errors.size
            %validator = \\{{validator_class}}.new
            %validator.validate_each(record, \\{{attribute.id.stringify}}, record.\\{{attribute.id}})
            record.errors.size == %before
          end
        \\{% end %}
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
  # record.valid?                   # runs all validators
  # record.valid?(context: :create) # runs :create and :save validators
  # record.valid?(context: :update) # runs :update and :save validators
  # ```
  def valid?(skip_normalization : Bool = false, context : Symbol? = nil)
    # Return false if any `ConversionError` were added
    # when setting model properties
    return false if errors.any? ConversionError

    errors.clear

    # Set flag for normalization to check
    @_skip_normalization = skip_normalization

    # `around_validation` callbacks wrap the entire validation phase
    # (before_validation -> validators -> after_validation), matching AR
    # semantics. If an around_validation callback fails to call its
    # continuation, the validation phase is halted (no validators run).
    __run_around_validation do
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
          errors << Error.new(validator[:field], validator[:message], validator[:code])
        end
      end

      # Run after_validation callbacks
      after_validation if responds_to?(:after_validation)
    end

    # Reset the flag
    @_skip_normalization = false

    errors.empty?
  end

  # Convenience inverse of `#valid?`. Returns `true` when the record has
  # validation errors, `false` when it is valid. Accepts the same `context`
  # argument as `#valid?` (AR-compatible).
  #
  # ```
  # record.invalid? # => !valid?
  # record.invalid?(context: :create)
  # ```
  def invalid?(skip_normalization : Bool = false, context : Symbol? = nil)
    !valid?(skip_normalization: skip_normalization, context: context)
  end
end
