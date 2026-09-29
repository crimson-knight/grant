require "./validator_info"
require "./error"
require "./errors"
require "./validation"
require "./validators/blank"

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

  # Reads the attribute through the record's generated typed reader
  # (`__read_validated_attribute`), so no `to_h` snapshot is built per
  # attribute. Non-column attributes read as nil.
  private def record_attribute(record, attribute)
    record.__read_validated_attribute(attribute)
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
  # Validation context symbols used with the `on:` option, alone or as an
  # Array (`on: [:create, :publish]`).
  #
  # - `:create` — runs only when creating a new record
  # - `:update` — runs only when updating an existing record
  # - `:save` — runs on both create and update (default)
  # - any other Symbol — a custom context, selected with `valid?(:publish)` or
  #   `save(context: :publish)`
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
    @errors ||= Errors.new(self)
  end

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @_skip_normalization : Bool?

  # The contexts of the validation run in progress, nil otherwise. Nilable
  # without a default for the same serialization reason as `@errors`.
  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @validation_contexts : Array(Symbol)?

  macro included
    macro inherited
      # `@@validators` is declared on every level, and each class stores only
      # its own validators. The block is wrapped as `Proc(Grant::Base, Bool)`
      # so every class in an STI hierarchy has the same class-variable type;
      # the wrapper casts back to the registering class before calling the
      # user's block, preserving access to subclass-only columns.
      #
      # Macro control flow nested in `macro included` is escaped with a leading
      # backslash so it evaluates at each subclass's `inherited` expansion.
      @@validators = Array({field: String, message: Grant::Error::Message, block: Proc(Grant::Base, Bool), contexts: Array(Symbol), code: Symbol?, strict: Proc(String, Exception) | Nil, details: Grant::Error::Options?, info: Grant::ValidatorInfo}).new

      \{% if @type.superclass.id == "Grant::Base" %}
      disable_grant_docs? def self.__validators_for_validation
        @@validators
      end
      \{% else %}
      disable_grant_docs? def self.__validators_for_validation
        \{{@type.superclass}}.__validators_for_validation + @@validators
      end
      \{% end %}

      # These registration methods are generated on every model class. An
      # inherited class method would specialize `self` to a child model while
      # still appending to its parent's class variable, producing incompatible
      # Proc types and registering the validator on the wrong class.
      disable_grant_docs? def self.__add_validator(field : (Symbol | String), message : String | Symbol | Proc(self, Grant::Error::Options, String) | Nil, block : self -> Bool, context : Symbol | Array(Symbol) = :save, code : Symbol? = nil, strict : Proc(String, Exception) | Nil = nil, kind : Symbol = :custom, details : Grant::Error::Options? = nil, info_options : Grant::Error::Options? = nil, conditional : Bool = false)
        wrapped_block = ->(record : Grant::Base) { block.call(record.as(\{{@type}})) }
        contexts = context.is_a?(Array) ? context : [context]
        info = Grant::ValidatorInfo.new(kind, field.to_s, info_options || Grant::Error::Options.new, contexts, conditional)
        @@validators << {field: field.to_s, message: Grant::Error.wrap_message(message), block: wrapped_block, contexts: contexts, code: code, strict: strict, details: details, info: info}
      end

      # The validators declared on this model and its ancestors, as
      # `Grant::ValidatorInfo` (kind, attribute, options, contexts).
      #
      # ```
      # User.validators_on(:email).map(&.kind) # => [:presence, :format]
      # ```
      disable_grant_docs? def self.validators : Array(Grant::ValidatorInfo)
        __validators_for_validation.map { |entry| entry[:info] }
      end

      # The validators that apply to any of *attributes*.
      disable_grant_docs? def self.validators_on(*attributes : Symbol | String) : Array(Grant::ValidatorInfo)
        names = attributes.map(&.to_s)
        validators.select { |info| names.includes?(info.attribute) }
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
        __add_validator(field, message, block, :save, code)
      end

      # Proc-based validate with context
      disable_grant_docs? def self.validate(field : (Symbol | String), message : String, block : self -> Bool, context : Symbol | Array(Symbol), code : Symbol? = nil)
        __add_validator(field, message, block, context, code)
      end

      # Block-based validate with context keyword (a Symbol or an Array of
      # them), optional error code, and optional `strict` factory that builds
      # the exception raised instead of adding an error.
      disable_grant_docs? def self.validate(field : (Symbol | String), message : String | Symbol | Proc(self, Grant::Error::Options, String) | Nil, *, context : Symbol | Array(Symbol) = :save, code : Symbol? = nil, strict : Proc(String, Exception) | Nil = nil, kind : Symbol = :custom, details : Grant::Error::Options? = nil, info_options : Grant::Error::Options? = nil, conditional : Bool = false, &block : self -> Bool)
        __add_validator(field, message, block, context, code, strict, kind, details, info_options, conditional)
      end

      \{% if @type.superclass.id == "Grant::Base" %}

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
        validate(:base, "", context: \\{{context}}, kind: :method, conditional: \\{{(options[:if] || options[:unless]) ? true : false}}) do |record|
          next true unless Grant::Conditions.met?(record, \\{{options[:if]}}, \\{{options[:unless]}}, nil, true)

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
          validate_method(\\{{name_or_method}}, \\{% for key, value in options %}\\{{key.id}}: \\{{value}}, \\{% end %})
        \\{% end %}
      end
      \{% end %}
    end
  end

  # ========================================================================
  # Built-in validators
  #
  # Every rule below registers through `__rule`, which owns the shared
  # plumbing: the `on:` contexts (a Symbol or an Array of Symbols),
  # `if:` / `unless:` conditions (a Symbol, a Proc, or an Array of them),
  # `allow_nil:` / `allow_blank:`, and `strict:`. All of them accept several
  # fields (`validates_length_of :a, :b, maximum: 10`) and apply the same
  # options to each.
  #
  # Validator bodies use block syntax so that `next` works inside `if` blocks.
  # ========================================================================

  # Registers one validator for *field*. The block runs with `record` (the
  # model) and, unless *read_value* is false, `value` (the field's current
  # value, already filtered by `allow_nil:` / `allow_blank:`), and returns true
  # when the record passes.
  #
  # :nodoc:
  macro __rule(rule_field, rule_message, rule_code, rule_read_value = true, **options, &block)
    {%
      context = options[:on] || :save
      strict = options[:strict]
      strict_class = nil
      if strict.is_a?(BoolLiteral)
        strict_class = "Grant::StrictValidationFailed".id if strict
      elsif !strict.is_a?(NilLiteral)
        strict_class = strict
      end
      skipped = %w(if unless on strict kind error_options)
      info_pairs = [] of String
      options.each do |key, value|
        unless skipped.includes?(key.stringify) || value.is_a?(ProcLiteral) || value.is_a?(ProcNotation)
          info_pairs << "#{key.id}: #{value}"
        end
      end
    %}
    validate({{rule_field}}, {{rule_message}}, context: {{context}}, code: {{rule_code}}, kind: {{options[:kind] || :custom}}, details: {% if options[:error_options] %}Grant::Error.options_from({{options[:error_options]}}){% else %}nil{% end %}, info_options: {% if info_pairs.empty? %}nil{% else %}Grant::Error.options_from({ {{info_pairs.join(", ").id}} }){% end %}, conditional: {{(options[:if] || options[:unless]) ? true : false}}{% if strict_class %}, strict: ->(strict_message : String) { {{strict_class}}.new(strict_message).as(Exception) }{% end %}) do |record|
      next true unless Grant::Conditions.met?(record, {{options[:if]}}, {{options[:unless]}}, nil, true)
      {% if rule_read_value %}
        value = record.{{rule_field.id}}
        {% if options[:allow_nil] %}
          next true if value.nil?
        {% end %}
        {% if options[:allow_blank] %}
          next true if Grant::Validators.blank?(value)
        {% end %}
      {% end %}
      {{block.body}}
    end
  end

  # Validates that a field is present: not `nil`, not `false`, not a blank
  # (whitespace-only) String and not an empty Array/Hash/Set. This is
  # ActiveRecord's `blank?` rule (see `Grant::Validators.blank?`).
  #
  # Options:
  # - `message:` — custom error message (default: `"can't be blank"`)
  # - `if:` / `unless:` — Symbol, Proc, or an Array of them
  # - `allow_nil:` / `allow_blank:` — skip the check for nil / blank values
  # - `on:` — validation context, or an Array of contexts (`:create`,
  #   `:update`, or any custom context passed to `valid?`)
  # - `strict:` — raise `Grant::StrictValidationFailed` (or the given
  #   exception class) instead of adding an error
  #
  # ```
  # validates_presence_of :name
  # validates_presence_of :name, :email # validates both fields
  # validates_presence_of :email, message: "is required"
  # validates_presence_of :reason, on: [:update, :publish], if: :requires_reason?
  # ```
  macro validates_presence_of(*fields, **options)
    {% message = options[:message] %}
    {% for field in fields %}
      __rule({{field}}, {{message}}, :blank, kind: :presence, {{options.double_splat}}) do
        !Grant::Validators.blank?(value)
      end
    {% end %}
  end

  # Validates that a field is absent (the inverse of presence): `nil`,
  # `false`, a blank String or an empty collection.
  #
  # ```
  # validates_absence_of :legacy_token
  # validates_absence_of :nickname, on: :create
  # validates_absence_of :legacy_token, :deprecated_flag # validates both
  # ```
  macro validates_absence_of(*fields, **options)
    {% message = options[:message] %}
    {% for field in fields %}
      __rule({{field}}, {{message}}, :present, kind: :absence, {{options.double_splat}}) do
        Grant::Validators.blank?(value)
      end
    {% end %}
  end

  # Validates format using regular expressions.
  #
  # - `with:` — a Regex that the value must match
  # - `without:` — a Regex that the value must NOT match
  # - `message:` (default: `"is invalid"`), `allow_nil:` / `allow_blank:`,
  #   `if:` / `unless:`, `on:`, `strict:`
  #
  # ```
  # validates_format_of :phone, with: /\A\d{3}-\d{3}-\d{4}\z/
  # validates_format_of :username, :nickname, without: /\A(admin|root)\z/, message: "is reserved"
  # ```
  macro validates_format_of(*fields, **options)
    {%
      with_pattern = options[:with]
      without_pattern = options[:without]
      message = options[:message]
    %}

    {% for field in fields %}
      __rule({{field}}, {{message}}, :invalid, kind: :format, {{options.double_splat}}) do
        string_value = value.to_s

        {% if with_pattern %}
          next false unless string_value.matches?({{with_pattern}})
        {% end %}
        {% if without_pattern %}
          next false if string_value.matches?({{without_pattern}})
        {% end %}

        true
      end
    {% end %}
  end

  # Validates the length of a string or array field.
  #
  # - `minimum:` / `min:` — minimum length required
  # - `maximum:` / `max:` — maximum length allowed
  # - `is:` — exact length required
  # - `in:` / `within:` — a range of acceptable lengths
  # - `message:`, `allow_nil:` / `allow_blank:`, `if:` / `unless:`, `on:`,
  #   `strict:`
  #
  # ```
  # validates_length_of :name, minimum: 2, maximum: 50
  # validates_length_of :first_name, :last_name, maximum: 30
  # validates_length_of :password, in: 8..128
  # ```
  macro validates_length_of(*fields, **options)
    {%
      minimum = options[:minimum] || options[:min]
      maximum = options[:maximum] || options[:max]
      exact = options[:is]
      range = options[:in] || options[:within]
      conditions = [] of String

      if minimum
        conditions << "at least " + minimum.stringify + " characters"
      end
      if maximum
        conditions << "at most " + maximum.stringify + " characters"
      end
      if exact
        conditions << "exactly " + exact.stringify + " characters"
      end
      if range
        conditions << "between " + range.begin.stringify + " and " + range.end.stringify + " characters"
      end

      message = options[:message] || (conditions.empty? ? "has incorrect length" : ("must be " + conditions.join(" and ")))

      # Most-specific AR length code when a single bound is given.
      len_code = :wrong_length
      if minimum && !maximum && !exact && !range
        len_code = :too_short
      elsif maximum && !minimum && !exact && !range
        len_code = :too_long
      end
    %}

    {% for field in fields %}
      __rule({{field}}, {{message}}, {{len_code}}, kind: :length, {% if len_code == :too_short %}error_options: {count: {{minimum}}}, {% elsif len_code == :too_long %}error_options: {count: {{maximum}}}, {% elsif exact && !minimum && !maximum && !range %}error_options: {count: {{exact}}}, {% end %}{{options.double_splat}}) do
        length = if value.responds_to?(:size)
                   value.size
                 else
                   value.to_s.size
                 end

        {% if minimum %}
          next false if length < {{minimum}}
        {% end %}
        {% if maximum %}
          next false if length > {{maximum}}
        {% end %}
        {% if exact %}
          next false unless length == {{exact}}
        {% end %}
        {% if range %}
          next false unless ({{range}}).includes?(length)
        {% end %}

        true
      end
    {% end %}
  end

  # Alias for `validates_length_of`.
  macro validates_size_of(*fields, **options)
    validates_length_of({{fields.splat}}, {{options.double_splat}})
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
  macro validates_confirmation_of(*fields, **options)
    {% message = options[:message] %}

    {% for field in fields %}
      # Create virtual attribute for confirmation
      property {{field.id}}_confirmation : String?

      __rule({{field}}, {{message}}, :confirmation, false, kind: :confirmation, {{options.double_splat}}) do
        confirmation_value = record.{{field.id}}_confirmation
        next true if confirmation_value.nil?

        record.{{field.id}}.to_s == confirmation_value
      end
    {% end %}
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
  macro validates_acceptance_of(*fields, **options)
    {%
      message = options[:message]
      accept_values = options[:accept] || ["1", "true", "yes", "on"]
    %}

    {% for field in fields %}
      # Acceptance values are virtual unless a model declares its own column.
      property {{field.id}} : String?

      __rule({{field}}, {{message}}, :accepted, false, kind: :acceptance, {{options.double_splat}}) do
        value = record.{{field.id}}

        case value
        when Nil
          {% if options[:allow_nil] %}true{% else %}false{% end %}
        when Bool
          value == true
        else
          {{accept_values}}.includes?(value.to_s.downcase)
        end
      end
    {% end %}
  end

  # Validates that associated records are also valid.
  #
  # ```
  # validates_associated :items
  # validates_associated :profile, :address
  # ```
  macro validates_associated(*associations, **options)
    {% message = options[:message] %}
    {% for association in associations %}
      __rule({{association}}, {{message}}, :invalid, false, kind: :associated, {{options.double_splat}}) do
        associated = record.{{association.id}}

        case associated
        when Nil
          true
        when Array
          associated.all? { |item| item.valid? }
        when Grant::AssociationCollection
          associated.to_a.all? { |item| item.valid? }
        when Grant::LoadedAssociationCollection
          associated.to_a.all? { |item| item.valid? }
        else
          associated.valid?
        end
      end
    {% end %}
  end

  # Validates that a value is included in a given set (`in:` or `within:`).
  #
  # ```
  # validates_inclusion_of :status, in: ["active", "inactive"]
  # validates_inclusion_of :role, :kind, in: ["admin", "user", "guest"]
  # ```
  macro validates_inclusion_of(*fields, **options)
    {%
      in_values = options[:in] || options[:within]
      message = options[:message]
    %}

    {% for field in fields %}
      __rule({{field}}, {{message}}, :inclusion, kind: :inclusion, {{options.double_splat}}) do
        ({{in_values}}).includes?(value)
      end
    {% end %}
  end

  # Validates that a value is NOT in a given set (`in:` or `within:`).
  #
  # ```
  # validates_exclusion_of :username, in: ["admin", "root", "superuser"]
  # ```
  macro validates_exclusion_of(*fields, **options)
    {%
      in_values = options[:in] || options[:within]
      message = options[:message]
    %}

    {% for field in fields %}
      __rule({{field}}, {{message}}, :exclusion, kind: :exclusion, {{options.double_splat}}) do
        !({{in_values}}).includes?(value)
      end
    {% end %}
  end

  # Validates a field by comparing it to another value (AR 7.1+).
  #
  # Comparison options: `greater_than:`, `greater_than_or_equal_to:`,
  # `equal_to:`, `less_than:`, `less_than_or_equal_to:`, `other_than:`. Each
  # operand may be a literal, or a Symbol naming an instance method (invoked
  # on the record to obtain the comparison value), enabling comparisons like
  # `started_at < ended_at`.
  #
  # ```
  # validates_comparison_of :age, greater_than_or_equal_to: 18
  # validates_comparison_of :ended_at, greater_than: :started_at
  # ```
  macro validates_comparison_of(*fields, **options)
    {%
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

    {% for field in fields %}
      __rule({{field}}, {{message}}, :comparison, kind: :comparison, {{options.double_splat}}) do
        # nil cannot be meaningfully compared; AR treats it as a failure.
        next false if value.nil?

        {% for c in comparisons %}
          {% operand = c[:operand] %}
          # A Symbol operand names an instance method to read at runtime;
          # any other operand is used as a literal value.
          {% if operand.is_a?(SymbolLiteral) %}
            %operand = record.{{operand.id}}
          {% else %}
            %operand = {{operand}}
          {% end %}
          next false if %operand.nil?
          next false unless value {{c[:op].id}} %operand
        {% end %}

        true
      end
    {% end %}
  end

  # Registers a reusable validator object (AR-compatible `validates_with`).
  #
  # The validator class must define an instance method `validate(record)`
  # that performs checks and adds errors to `record.errors`. A fresh
  # instance is created per validation run, so validators should be stateless
  # (or accept configuration through constructor arguments forwarded here).
  #
  # `on:`, `if:`, `unless:` and `strict:` are consumed here; every other
  # keyword is forwarded to the validator's constructor, mirroring AR's
  # `validates_with MyValidator, option: 1`.
  #
  # ```
  # class EvenValidator < Grant::Validator
  #   def validate(record)
  #     record.errors.add(:value, "must be even", type: :even) if record.value.odd?
  #   end
  # end
  #
  # class Counter < Grant::Base
  #   validates_with EvenValidator, on: [:create, :update]
  # end
  # ```
  macro validates_with(validator_class, *args, **options)
    __rule(:base, "", nil, false, kind: :with, {{options.double_splat}}) do
      %before = record.errors.size
      %validator = {{validator_class}}.new({% for a in args %}{{a}}, {% end %}{% for k, v in options %}{% unless %w(on if unless strict).includes?(k.stringify) %}{{k.id}}: {{v}}, {% end %}{% end %})
      %validator.validate(record)
      record.errors.size == %before
    end
  end

  # Attribute-scoped validation, in two forms.
  #
  # With a block (AR's `validates_each`): the block runs once per attribute
  # with the record, the attribute name as a Symbol and its value, and adds
  # its own errors. `allow_nil:` / `allow_blank:` skip the block for such
  # values, and a bare `next` inside the block skips the rest of it.
  #
  # ```
  # validates_each :first_name, :last_name, allow_nil: true do |record, attr, value|
  #   record.errors.add(attr, "must start with a capital") if value[0]? && value[0].lowercase?
  # end
  # ```
  #
  # With `with:`, a `Grant::EachValidator` subclass runs per attribute:
  #
  # ```
  # validates_each :email, :name, with: PresenceEachValidator
  # ```
  #
  # `args:` (a NamedTuple) is forwarded to the validator's constructor.
  macro validates_each(*attributes, **options, &block)
    {% validator_class = options[:with] %}
    {% if block.is_a?(Block) && validator_class %}
      {% raise "validates_each takes either a block or `with:`, not both" %}
    {% elsif !block.is_a?(Block) && !validator_class %}
      {% raise "validates_each requires a block or `with:` naming an EachValidator subclass" %}
    {% end %}
    {% for attribute in attributes %}
      {% if block.is_a?(Block) %}
        __rule({{attribute}}, "", nil, kind: :each, {{options.double_splat}}) do
          {% if block.args.size > 0 && block.args[0].id.stringify != "record" %}{{block.args[0].id}} = record{% end %}
          {% if block.args.size > 1 %}{{block.args[1].id}} = :{{attribute.id}}{% end %}
          {% if block.args.size > 2 && block.args[2].id.stringify != "value" %}{{block.args[2].id}} = value{% end %}
          %before = record.errors.size
          # `1.times` gives the user's block body its own block scope, so a
          # bare `next` (the Ruby idiom for skipping a value) ends the body
          # instead of returning nil from the validator. It inlines at compile
          # time and allocates nothing.
          1.times do
            {{block.body}}
          end
          record.errors.size == %before
        end
      {% else %}
        __rule({{attribute}}, "", nil, kind: :each, {{options.double_splat}}) do
          %before = record.errors.size
          %validator = {{validator_class}}.new({% if options[:args] %}{{options[:args].double_splat}}{% end %})
          %validator.validate_each(record, {{attribute.id.stringify}}, value)
          record.errors.size == %before
        end
      {% end %}
    {% end %}
  end

  # Validates that a field is a valid email address using
  # `Grant::Validators::BuiltIn::CommonFormats::EMAIL_REGEX`. Takes the same
  # options as `validates_format_of` (except `with:`).
  #
  # ```
  # validates_email :email
  # validates_email :email, :contact_email, message: "must be a valid email"
  # ```
  macro validates_email(*fields, **options)
    validates_format_of({{fields.splat}}, with: Grant::Validators::BuiltIn::CommonFormats::EMAIL_REGEX, message: {{options[:message] || "is not a valid email"}}, {% for k, v in options %}{% unless k.stringify == "message" %}{{k.id}}: {{v}}, {% end %}{% end %})
  end

  # Validates that a field is a valid URL using
  # `Grant::Validators::BuiltIn::CommonFormats::URL_REGEX`. Takes the same
  # options as `validates_format_of` (except `with:`).
  #
  # ```
  # validates_url :website
  # validates_url :homepage, message: "must be a valid URL"
  # ```
  macro validates_url(*fields, **options)
    validates_format_of({{fields.splat}}, with: Grant::Validators::BuiltIn::CommonFormats::URL_REGEX, message: {{options[:message] || "is not a valid URL"}}, {% for k, v in options %}{% unless k.stringify == "message" %}{{k.id}}: {{v}}, {% end %}{% end %})
  end

  # AR-style unified validation macro.
  #
  # Expands at compile time into the matching `validates_*_of` calls, so it
  # costs nothing at run time. The options shared by every validator in the
  # call are `if:`, `unless:`, `on:`, `allow_nil:`, `allow_blank:` and
  # `strict:`; every other key names a validator and takes `true` or the
  # options for that validator.
  #
  # Built-in keys: `presence`, `absence`, `length`, `size`, `numericality`,
  # `format`, `inclusion`, `exclusion`, `comparison`, `confirmation`,
  # `acceptance`, `uniqueness`, `email`, `url`, `associated`. Shorthands:
  # `length: 2..40`, `length: 5`, `format: /@/`, `inclusion: %w(a b)`.
  #
  # Any other key resolves to the `Grant::EachValidator` subclass named
  # `<Key>Validator` (`strong_password: true` looks for `StrongPasswordValidator`)
  # and is a compile error when no such class exists.
  #
  # ```
  # validates :name, :email, presence: true, length: {min: 2, max: 40}, allow_nil: true, on: :create
  # validates :email, format: {with: /@/}, uniqueness: true
  # validates :password, strong_password: true
  # ```
  macro validates(*fields, **options)
    {%
      shared = [] of ArrayLiteral
      shared_keys = %w(if unless on allow_nil allow_blank strict)
      options.each do |key, value|
        shared << [key, value] if shared_keys.includes?(key.stringify)
      end

      builtins = {
        "presence"     => "validates_presence_of",
        "absence"      => "validates_absence_of",
        "length"       => "validates_length_of",
        "size"         => "validates_length_of",
        "numericality" => "validates_numericality_of",
        "format"       => "validates_format_of",
        "inclusion"    => "validates_inclusion_of",
        "exclusion"    => "validates_exclusion_of",
        "comparison"   => "validates_comparison_of",
        "confirmation" => "validates_confirmation_of",
        "acceptance"   => "validates_acceptance_of",
        "uniqueness"   => "validates_uniqueness_of",
        "email"        => "validates_email",
        "url"          => "validates_url",
        "associated"   => "validates_associated",
      }
    %}
    {% for key, value in options %}
      {% unless shared_keys.includes?(key.stringify) %}
        {% name = key.stringify %}
        {% if value.is_a?(BoolLiteral) && !value %}
          # `key: false` disables the validator, as in AR.
        {% elsif builtins[name] %}
          {% inner = [] of ArrayLiteral %}
          {% if value.is_a?(NamedTupleLiteral) %}
            {% value.each { |k, v| inner << [k, v] } %}
          {% elsif value.is_a?(BoolLiteral) %}
          {% elsif value.is_a?(RegexLiteral) && name == "format" %}
            {% inner << [:with, value] %}
          {% elsif (value.is_a?(ArrayLiteral) || value.is_a?(RangeLiteral)) && (name == "inclusion" || name == "exclusion") %}
            {% inner << [:in, value] %}
          {% elsif value.is_a?(RangeLiteral) && (name == "length" || name == "size") %}
            {% inner << [:in, value] %}
          {% elsif value.is_a?(NumberLiteral) && (name == "length" || name == "size") %}
            {% inner << [:is, value] %}
          {% else %}
            {% key.raise "validates: `#{key.id}:` expects true or a NamedTuple of options" %}
          {% end %}
          {{builtins[name].id}}({{fields.splat}}, {% for pair in inner %}{{pair[0].id}}: {{pair[1]}}, {% end %}{% for pair in shared %}{{pair[0].id}}: {{pair[1]}}, {% end %})
        {% else %}
          {% validator_type = parse_type("#{name.camelcase.id}Validator").resolve? %}
          {% unless validator_type %}
            {% key.raise "validates: unknown key `#{key.id}:`. Built-in keys are #{builtins.keys.join(", ").id}; a custom key needs a `Grant::EachValidator` subclass named #{name.camelcase.id}Validator (options such as `message:` go inside the validator's own options)." %}
          {% end %}
          validates_each({{fields.splat}}, with: {{validator_type}}, {% if value.is_a?(NamedTupleLiteral) %}args: {{value}}, {% end %}{% for pair in shared %}{{pair[0].id}}: {{pair[1]}}, {% end %})
        {% end %}
      {% end %}
    {% end %}
  end

  # Runs all of `self`'s validators, returning `true` if they all pass, and `false`
  # otherwise.
  #
  # If the validation fails, `#errors` will contain all the errors responsible for
  # the failing.
  #
  # The validation context selects which validators run. It defaults to
  # `:create` for a new record and `:update` for a persisted one (ActiveRecord
  # semantics), or is given explicitly as a Symbol or an Array of Symbols. A
  # validator without `on:` always runs; one with `on:` runs when any of its
  # contexts is active. Passing `:save` explicitly runs every validator.
  #
  # ```
  # record.valid?                   # :create for a new record, :update otherwise
  # record.valid?(:publish)         # validators without on: plus on: :publish
  # record.valid?(context: :update) # keyword form
  # record.valid?(context: [:create, :publish])
  # ```
  def valid?(skip_normalization : Bool = false, context : Symbol | Array(Symbol) | Nil = nil)
    # Return false if any `ConversionError` were added
    # when setting model properties
    return false if errors.any? ConversionError

    errors.clear

    # Set flag for normalization to check
    @_skip_normalization = skip_normalization

    previous_contexts = @validation_contexts
    active_contexts = if context.is_a?(Array)
                        context
                      elsif context
                        [context]
                      else
                        [new_record? ? :create : :update]
                      end
    @validation_contexts = active_contexts

    begin
      # `around_validation` callbacks wrap the entire validation phase
      # (before_validation -> validators -> after_validation), matching AR
      # semantics. If an around_validation callback fails to call its
      # continuation, the validation phase is halted (no validators run).
      __run_around_validation do
        # Run before_validation callbacks
        before_validation if responds_to?(:before_validation)

        run_all = active_contexts.includes?(:save)
        self.class.__validators_for_validation.each do |validator|
          unless run_all
            validator_contexts = validator[:contexts]
            # No `on:` (stored as :save) always runs; otherwise a context must match
            next unless validator_contexts.includes?(:save) || validator_contexts.any? { |candidate| active_contexts.includes?(candidate) }
          end

          errors_before = errors.size
          unless validator[:block].call(self)
            message = validator[:message]
            failure = Error.new(validator[:field], message, validator[:code], options: validator[:details], base: self)
            # Validators that add their own errors (`validates_with`,
            # `validates_each`, `validate :method`) carry an empty message.
            own_errors = message.is_a?(String) && message.empty?
            strict_factory = validator[:strict]
            if strict_factory
              added = errors.last?
              raise strict_factory.call(own_errors && added ? added.to_s : failure.to_s)
            end
            # They need no placeholder next to the errors they already recorded.
            errors << failure unless own_errors && errors.size > errors_before
          end
        end

        # Run after_validation callbacks
        after_validation if responds_to?(:after_validation)
      end
    ensure
      @validation_contexts = previous_contexts
      # Reset the flag
      @_skip_normalization = false
    end

    errors.empty?
  end

  # Positional form: `record.valid?(:publish)`.
  def valid?(context : Symbol | Array(Symbol))
    valid?(context: context)
  end

  # Convenience inverse of `#valid?`. Returns `true` when the record has
  # validation errors, `false` when it is valid. Accepts the same `context`
  # argument as `#valid?` (AR-compatible).
  #
  # ```
  # record.invalid? # => !valid?
  # record.invalid?(:publish)
  # record.invalid?(context: :create)
  # ```
  def invalid?(skip_normalization : Bool = false, context : Symbol | Array(Symbol) | Nil = nil)
    !valid?(skip_normalization: skip_normalization, context: context)
  end

  # Positional form: `record.invalid?(:publish)`.
  def invalid?(context : Symbol | Array(Symbol))
    !valid?(context: context)
  end

  # ActiveModel's `validate(context)`: an alias for `#valid?`.
  def validate(context : Symbol | Array(Symbol) | Nil = nil) : Bool
    valid?(context: context)
  end

  # Runs the validations and raises `Grant::RecordInvalid` when the record is
  # invalid. Returns the record, so it can be chained. Takes the same context
  # as `#valid?`.
  #
  # ```
  # post.validate! # => post, or raises Grant::RecordInvalid
  # post.validate!(:publish)
  # ```
  def validate!(context : Symbol | Array(Symbol) | Nil = nil) : self
    valid?(context: context) || raise Grant::RecordInvalid.new(self)
    self
  end

  # The context validation is currently running in (the first one when several
  # are active), or nil outside a validation run. Custom validators and
  # validation callbacks can branch on it.
  def validation_context : Symbol?
    contexts = @validation_contexts
    contexts ? contexts.first? : nil
  end

  # Every context validation is currently running in; empty outside a run.
  def validation_contexts : Array(Symbol)
    @validation_contexts || [] of Symbol
  end

  # True while validation is running in *context*. Used by `on:` conditions on
  # `before_validation` / `after_validation` callbacks.
  #
  # :nodoc:
  def __in_validation_context?(context : Symbol) : Bool
    contexts = @validation_contexts
    contexts ? contexts.includes?(context) : false
  end

  # Reads a column value by name through a generated `case`, without building
  # a `to_h` snapshot. Names that are not columns read as nil.
  #
  # :nodoc:
  def __read_validated_attribute(name : String)
    {% begin %}
    case name
    {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
      when {{column.name.stringify}}
        begin
          {{column.name.id}}
        rescue NilAssertionError
          nil
        end
    {% end %}
    else
      nil
    end
    {% end %}
  end
end
