module Grant::Validators
  # The number *value* stands for: a Number as is, a String that parses as
  # one, otherwise nil (NaN and infinity are not numbers here).
  #
  # :nodoc:
  def self.numeric_value(value) : Int64 | Float64 | Nil
    nil
  end

  # :nodoc:
  def self.numeric_value(value : Int) : Int64 | Float64 | Nil
    value > Int64::MAX ? value.to_f64 : value.to_i64
  end

  # :nodoc:
  def self.numeric_value(value : Float) : Int64 | Float64 | Nil
    value.finite? ? value.to_f64 : nil
  end

  # :nodoc:
  def self.numeric_value(value : Number) : Int64 | Float64 | Nil
    value.to_f64
  end

  # :nodoc:
  def self.numeric_value(value : String) : Int64 | Float64 | Nil
    value.strip.to_i64? || value.strip.to_f64?.try { |float| float.finite? ? float : nil }
  end

  # The numeric operand of a constraint (`greater_than: :minimum_price`),
  # raising when it does not resolve to a number, as ActiveRecord does.
  #
  # :nodoc:
  def self.numeric_operand(option : String, operand) : Int64 | Float64
    numeric_value(operand) || raise ArgumentError.new("#{option} must be a number, got #{operand.inspect}")
  end

  # True when a numeric *value* has no fractional part and *raw* was not
  # written with one (`"1.5"`).
  #
  # :nodoc:
  def self.integer_value?(raw, number : Int64 | Float64) : Bool
    return true if number.is_a?(Int64)
    return false unless raw.is_a?(Float) || raw.is_a?(Number)
    number == number.floor
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
      __rule({{field}}, "", nil, kind: :numericality, {{options.double_splat}}) do
        %before = record.errors.size
        %message = Grant::Error.wrap_message({% if options[:message] %}{{options[:message]}}{% else %}nil{% end %})
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
