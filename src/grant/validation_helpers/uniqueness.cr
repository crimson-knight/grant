module Grant::ValidationHelpers
  # Validates that *field*'s value is unique across the table.
  #
  # Issues a `find_by(field: value)` and fails when a *different* record (by
  # `id`) already has that value. A `nil` value is skipped (passes). This is
  # the lightweight counterpart to `validates_uniqueness_of`; reach for that
  # macro when you need `scope:`, `case_sensitive:`, custom messages, or
  # contexts.
  #
  # NOTE: like all uniqueness checks, this is subject to a check-then-insert
  # race; pair it with a database `UNIQUE` index for a hard guarantee.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column email : String?
  #   validate_uniqueness :email
  # end
  #
  # User.create(email: "a@example.com")
  # User.new(email: "a@example.com").valid? # => false (already taken)
  # User.new(email: "b@example.com").valid? # => true
  # ```
  macro validate_uniqueness(field)
    validate {{field}}, "#{{{field}}} should be unique", -> (model: self) do
      return true if model.{{field.id}}.nil?

      instance = self.find_by({{field.id}}: model.{{field.id}})

      !(instance && instance.id != model.id)
    end
  end
end
