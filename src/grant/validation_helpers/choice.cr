module Grant::ValidationHelpers
  # Validates that *field*'s value is one of *choices*.
  #
  # *choices* is any collection that responds to `includes?` (an array, a set,
  # a range). Adds the error
  # `"<field> has an invalid choice. Valid choices are: <choices>"` when the
  # value is not a member. For custom messages, contexts, or `allow_nil`, use
  # `validates_inclusion_of`.
  #
  # ```
  # class Ticket < Grant::Base
  #   column id : Int64, primary: true
  #   column status : String?
  #   validate_is_valid_choice :status, ["open", "closed", "pending"]
  # end
  #
  # Ticket.new(status: "open").valid?     # => true
  # Ticket.new(status: "archived").valid? # => false
  # ```
  macro validate_is_valid_choice(field, choices)
    validate {{field}}, "#{{{field}}} has an invalid choice. Valid choices are: #{{{choices.join(',')}}}", Proc(self, Bool).new { |model| {{choices}}.includes? model.{{field.id}} }
  end
end
