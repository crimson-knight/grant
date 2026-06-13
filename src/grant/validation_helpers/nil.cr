module Grant::ValidationHelpers
  # Validates that *field* is not `nil`.
  #
  # Only checks for `nil` — an empty or whitespace-only string passes (use
  # `validate_not_blank` to reject those too). Adds the error
  # `"<field> must not be nil"` on failure. For custom messages/contexts, use
  # `validates_presence_of`.
  #
  # ```
  # class Event < Grant::Base
  #   column id : Int64, primary: true
  #   column starts_at : String?
  #   validate_not_nil :starts_at
  # end
  #
  # Event.new(starts_at: "2026-01-01").valid? # => true
  # Event.new.valid?                          # => false
  # ```
  macro validate_not_nil(field)
    validate {{field}}, "#{{{field}}} must not be nil", Proc(self, Bool).new { |model| !model.{{field.id}}.nil? }
  end

  # Validates that *field* is `nil`.
  #
  # The inverse of `validate_not_nil`. Adds the error
  # `"<field> must be nil"` when *field* holds any non-nil value. For custom
  # messages/contexts, use `validates_absence_of`.
  #
  # ```
  # class Import < Grant::Base
  #   column id : Int64, primary: true
  #   column error_message : String?
  #   validate_is_nil :error_message
  # end
  #
  # Import.new.valid?                        # => true
  # Import.new(error_message: "boom").valid? # => false
  # ```
  macro validate_is_nil(field)
    validate {{field}}, "#{{{field}}} must be nil", Proc(self, Bool).new { |model| model.{{field.id}}.nil? }
  end
end
