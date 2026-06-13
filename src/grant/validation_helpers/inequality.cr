module Grant::ValidationHelpers
  # Validates that *field* is greater than *amount* (or `>=` when
  # *or_equal_to* is `true`).
  #
  # The value is read with `not_nil!`, so a `nil` *field* raises rather than
  # failing the validation — pair it with `validate_not_nil` or a column
  # default when the field is nilable. Adds the error
  # `"<field> must be greater than[ or equal to] <amount>"` on failure. For
  # nil-safe checks with custom messages/contexts, use
  # `validates_numericality_of` or `validates_comparison_of`.
  #
  # ```
  # class Product < Grant::Base
  #   column id : Int64, primary: true
  #   column price : Float64 = 0.0
  #   validate_greater_than :price, 0                    # strictly > 0
  #   validate_greater_than :price, 0, or_equal_to: true # >= 0
  # end
  #
  # Product.new(price: 9.99).valid? # => true
  # Product.new(price: 0.0).valid?  # => false (strict form)
  # ```
  macro validate_greater_than(field, amount, or_equal_to = false)
    validate {{field}}, "#{{{field}}} must be greater than#{{{or_equal_to}} ? " or equal to" : ""} #{{{amount}}}", Proc(self, Bool).new { |model| (model.{{field.id}}.not_nil! {% if or_equal_to %} >= {% else %} > {% end %} {{amount.id}}) }
  end

  # Validates that *field* is less than *amount* (or `<=` when *or_equal_to*
  # is `true`).
  #
  # The value is read with `not_nil!`, so a `nil` *field* raises rather than
  # failing the validation. Adds the error
  # `"<field> must be less than[ or equal to] <amount>"` on failure. For
  # nil-safe checks with custom messages/contexts, use
  # `validates_numericality_of` or `validates_comparison_of`.
  #
  # ```
  # class Order < Grant::Base
  #   column id : Int64, primary: true
  #   column quantity : Int32 = 1
  #   validate_less_than :quantity, 100                    # strictly < 100
  #   validate_less_than :quantity, 100, or_equal_to: true # <= 100
  # end
  #
  # Order.new(quantity: 99).valid?  # => true
  # Order.new(quantity: 100).valid? # => false (strict form)
  # ```
  macro validate_less_than(field, amount, or_equal_to = false)
    validate {{field}}, "#{{{field}}} must be less than#{{{or_equal_to}} ? " or equal to" : ""} #{{{amount}}}", Proc(self, Bool).new { |model| (model.{{field.id}}.not_nil! {% if or_equal_to %} <= {% else %} < {% end %} {{amount.id}}) }
  end
end
