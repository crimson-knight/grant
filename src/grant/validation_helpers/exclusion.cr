module Grant::ValidationHelpers
  # Validates that *field*'s value is NOT one of *excluded_values* (the inverse
  # of `validate_is_valid_choice`).
  #
  # *excluded_values* is any collection that responds to `includes?`. Adds the
  # error
  # `"<Field> got reserved values. Reserved values are <excluded_values>"` when
  # the value is a member. For custom messages, contexts, or `allow_nil`, use
  # `validates_exclusion_of`.
  #
  # ```
  # class Account < Grant::Base
  #   column id : Int64, primary: true
  #   column username : String?
  #   validate_exclusion :username, ["admin", "root", "system"]
  # end
  #
  # Account.new(username: "alice").valid? # => true
  # Account.new(username: "admin").valid? # => false
  # ```
  macro validate_exclusion(field, excluded_values)
    validate {{field}}, "#{{{field.capitalize}}} got reserved values. Reserved values are #{{{excluded_values.join(',')}}}", Proc(self, Bool).new { |model| !{{excluded_values}}.includes? model.{{field.id}}}
  end
end
