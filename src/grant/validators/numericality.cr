module Grant::Validators
  # The number *value* stands for: a Number as is, a String that parses as
  # one, otherwise nil (NaN and infinity are not numbers here).
  #
  # :nodoc:
  def self.numeric_value(value) : Int64 | Float64?
    nil
  end

  # :nodoc:
  def self.numeric_value(value : Int) : Int64 | Float64?
    value > Int64::MAX ? value.to_f64 : value.to_i64
  end

  # :nodoc:
  def self.numeric_value(value : Float) : Int64 | Float64?
    value.finite? ? value.to_f64 : nil
  end

  # :nodoc:
  def self.numeric_value(value : Number) : Int64 | Float64?
    value.to_f64
  end

  # :nodoc:
  def self.numeric_value(value : String) : Int64 | Float64?
    value.strip.to_i64? || value.strip.to_f64?.try { |float| float.finite? ? float : nil }
  end

  # The numeric operand of a constraint (`greater_than: :minimum_price`),
  # raising when it does not resolve to a number, as ActiveRecord does.
  #
  # :nodoc:
  def self.numeric_operand(option : String, operand) : Int64 | Float64
    numeric_value(operand) || raise ArgumentError.new("#{option} must be a number, got #{operand.inspect}")
  end

  # True when *number* is an integer: it came from an Integer or from text
  # without a fractional part. A Float is never an integer here, even `8.0`,
  # because ActiveRecord checks the written form (`"8.0"`).
  #
  # :nodoc:
  def self.integer_value?(raw, number : Int64 | Float64) : Bool
    number.is_a?(Int64) || raw.is_a?(Int)
  end

  # The error type for an input that was not stored because it does not fit the
  # column (`"1.5"` for an Int32 column, `"99999999999"` for an Int32): text
  # that parses as a number but not as an integer is `:not_an_integer`, any
  # other number is `:out_of_range`.
  #
  # :nodoc:
  def self.unstorable_type(number : Int64 | Float64) : Symbol
    number.is_a?(Float64) ? :not_an_integer : :out_of_range
  end

  # Validates that a numeric field meets specified criteria. Every failing
  # constraint adds its own error, with its own type and options, like
  # ActiveRecord: a value of `-1.5` with `greater_than: 0, only_integer: true`
  # gets `:not_an_integer` and stops there; `-4` with `greater_than: 0, odd:
  # true` gets `:greater_than` (`count: 0`, `value: -4`) and `:odd`.
  #
  # A value that is not a number (or a String that does not parse as one)
  # adds `:not_a_number` (`"is not a number"`, `value:` the input).
  #
  # Constraints: `greater_than:`, `greater_than_or_equal_to:`, `less_than:`,
  # `less_than_or_equal_to:`, `equal_to:`, `other_than:`, `odd:`, `even:`,
  # `only_integer:`, `in:` (a Range, reported as `greater_than_or_equal_to`
  # and `less_than_or_equal_to`, or `less_than` for an exclusive end).
  #
  # A comparison operand is a number, a Symbol naming another attribute or
  # method of the record (`greater_than: :minimum_price`), or a lambda that
  # takes the record (`less_than: ->(order : Order) { order.limit }`).
  #
  # Input that cannot be stored in a numeric column (`"abc"` assigned to an
  # Int32 column) does not raise: the numericality validator on that attribute
  # reports `:not_a_number` (or `:not_an_integer` for `"1.5"`) with the input as
  # `value:`. Without such a validator the record stays invalid with a
  # `Grant::ConversionError`.
  #
  # `only_integer:` rejects a Float even when it has no fractional part, as
  # ActiveRecord does. `only_numeric: true` takes a String value as not a
  # number instead of parsing it.
  #
  # Also: `message:` (a String, a Symbol translation key or a lambda; used for
  # every error this validator adds), `allow_nil:` / `allow_blank:`,
  # `if:` / `unless:`, `on:`, `strict:`.
  #
  # ```
  # validates_numericality_of :price, greater_than: 0
  # validates_numericality_of :price, :cost, greater_than_or_equal_to: 0
  # validates_numericality_of :score, in: 1..10
  # validates_numericality_of :maximum, greater_than: :minimum
  # ```
  macro validates_numericality_of(*fields, **options)
    {%
      comparisons = [
        {key: :greater_than, op: ">"},
        {key: :greater_than_or_equal_to, op: ">="},
        {key: :equal_to, op: "=="},
        {key: :less_than, op: "<"},
        {key: :less_than_or_equal_to, op: "<="},
        {key: :other_than, op: "!="},
      ]
    %}

    {% for field in fields %}
      __rule({{field}}, "", nil, false, kind: :numericality, {{options.double_splat}}) do
        %before = record.errors.size
        %message = Grant::Error.wrap_message({% if options[:message] %}{{options[:message]}}{% else %}nil{% end %})
        # Input that could not be converted to the column's type (`"abc"` for
        # an Int32 column) is judged as typed. Nil on every record whose
        # assignments converted.
        %input = record.__unconvertible_input({{field.id.stringify}})
        unless %input.nil?
          {% if options[:allow_blank] %}
            next true if Grant::Validators.blank?(%input)
          {% end %}
          %typed = {% if options[:only_numeric] %}nil.as(Int64 | Float64 | Nil){% else %}Grant::Validators.numeric_value(%input){% end %}
          if %typed.nil?
            record.errors.add({{field.id.stringify}}, :not_a_number, message: %message, value: %input)
          else
            record.errors.add({{field.id.stringify}}, Grant::Validators.unstorable_type(%typed), message: %message, value: %input)
          end
          next false
        end

        value = record.{{field.id}}
        {% if options[:allow_nil] %}
          next true if value.nil?
        {% end %}
        {% if options[:allow_blank] %}
          next true if Grant::Validators.blank?(value)
        {% end %}

        {% if options[:only_numeric] %}
          # `only_numeric: true` takes text as not numeric, even "42".
          if value.is_a?(String)
            record.errors.add({{field.id.stringify}}, :not_a_number, message: %message, value: value)
            next false
          end
        {% end %}
        %number = Grant::Validators.numeric_value(value)
        if %number.nil?
          record.errors.add({{field.id.stringify}}, :not_a_number, message: %message, value: value)
          next false
        end

        {% if options[:only_integer] %}
          unless Grant::Validators.integer_value?(value, %number)
            record.errors.add({{field.id.stringify}}, :not_an_integer, message: %message, value: value)
            next false
          end
        {% end %}

        {% for comparison in comparisons %}
          {% operand = options[comparison[:key]] %}
          {% if operand != nil && operand != false %}
            {% if operand.is_a?(SymbolLiteral) %}
              %bound = Grant::Validators.numeric_operand({{comparison[:key].stringify}}, record.{{operand.id}})
            {% elsif operand.is_a?(ProcLiteral) || operand.is_a?(ProcNotation) %}
              %bound = Grant::Validators.numeric_operand({{comparison[:key].stringify}}, ({{operand}}).call(record))
            {% else %}
              %bound = Grant::Validators.numeric_operand({{comparison[:key].stringify}}, {{operand}})
            {% end %}
            unless %number {{comparison[:op].id}} %bound
              record.errors.add({{field.id.stringify}}, {{comparison[:key]}}, message: %message, count: %bound, value: value)
            end
          {% end %}
        {% end %}

        {% if options[:odd] %}
          unless %number.to_i64.odd?
            record.errors.add({{field.id.stringify}}, :odd, message: %message, value: value)
          end
        {% end %}
        {% if options[:even] %}
          unless %number.to_i64.even?
            record.errors.add({{field.id.stringify}}, :even, message: %message, value: value)
          end
        {% end %}

        {% if options[:in] %}
          %range = {{options[:in]}}
          %range_begin = %range.begin
          if %range_begin && !(%number >= %range_begin)
            record.errors.add({{field.id.stringify}}, :greater_than_or_equal_to, message: %message, count: %range_begin, value: value)
          end
          %range_end = %range.end
          if %range_end
            if %range.excludes_end?
              record.errors.add({{field.id.stringify}}, :less_than, message: %message, count: %range_end, value: value) unless %number < %range_end
            else
              record.errors.add({{field.id.stringify}}, :less_than_or_equal_to, message: %message, count: %range_end, value: value) unless %number <= %range_end
            end
          end
        {% end %}

        record.errors.size == %before
      end
    {% end %}
  end
end
