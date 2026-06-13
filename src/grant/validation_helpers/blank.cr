# Lightweight `validate_*` helper macros.
#
# `Grant::ValidationHelpers` provides a set of terse, single-purpose validation
# macros (`validate_not_blank`, `validate_min_length`, `validate_greater_than`,
# `validate_is_valid_choice`, `validate_uniqueness`, etc.). Each expands to a
# single `validate` registration with a pre-built message, so they are a quick
# way to add a common check without spelling out a block.
#
# These are simpler than (and predate) the richer `validates_*` family in
# `Grant::Validators` — they take no `:if`/`:unless`/`:on`/`:message`/
# `:allow_nil` options and always run on `:save`. Reach for the `validates_*`
# macros (e.g. `validates_presence_of`, `validates_length_of`) when you need
# those options or AR-style error codes; reach for these when you just want a
# one-liner with the default message.
#
# ```
# class User < Grant::Base
#   column id : Int64, primary: true
#   column name : String?
#   column age : Int32?
#
#   validate_not_blank :name
#   validate_greater_than :age, 0
# end
# ```
module Grant::ValidationHelpers
  # Validates that *field* is not blank — i.e. its string form is neither empty
  # nor whitespace-only (and not `nil`).
  #
  # Adds the error `"<field> must not be blank"` when the check fails. For
  # custom messages, contexts, or `allow_nil`, use `validates_presence_of`.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column name : String?
  #   validate_not_blank :name
  # end
  #
  # User.new(name: "").valid?    # => false
  # User.new(name: "Ada").valid? # => true
  # ```
  macro validate_not_blank(field)
    validate {{field}}, "#{{{field}}} must not be blank", Proc(self, Bool).new { |model| !model.{{field.id}}.to_s.blank? }
  end

  # Validates that *field* is blank — i.e. `nil`, empty, or whitespace-only.
  #
  # The inverse of `validate_not_blank`. Adds the error
  # `"<field> must be blank"` when *field* holds a non-blank value. For custom
  # messages or contexts, use `validates_absence_of`.
  #
  # ```
  # class Draft < Grant::Base
  #   column id : Int64, primary: true
  #   column published_at : String?
  #   validate_is_blank :published_at
  # end
  #
  # Draft.new(published_at: "2026-01-01").valid? # => false
  # Draft.new.valid?                             # => true
  # ```
  macro validate_is_blank(field)
    validate {{field}}, "#{{{field}}} must be blank", Proc(self, Bool).new { |model| model.{{field.id}}.to_s.blank? }
  end
end
