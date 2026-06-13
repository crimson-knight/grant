module Grant::ValidationHelpers
  # Validates that *field*'s `size` is at least *length*.
  #
  # The value is read with `not_nil!` before calling `size`, so a `nil`
  # *field* raises rather than failing the validation — guard nilable fields
  # with `validate_not_nil` first. Works on anything that responds to `size`
  # (`String`, `Array`). Adds the error
  # `"<field> is too short. It must be at least <length>"` on failure. For
  # nil-safe checks with custom messages/contexts/ranges, use
  # `validates_length_of`.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column password : String = ""
  #   validate_min_length :password, 8
  # end
  #
  # User.new(password: "supersecret").valid? # => true
  # User.new(password: "short").valid?       # => false
  # ```
  macro validate_min_length(field, length)
    validate {{field}}, "#{{{field}}} is too short. It must be at least #{{{length}}}", Proc(self, Bool).new { |model| (model.{{field.id}}.not_nil!.size >= {{length.id}}) }
  end

  # Validates that *field*'s `size` is at most *length*.
  #
  # The value is read with `not_nil!` before calling `size`, so a `nil`
  # *field* raises rather than failing the validation. Works on anything that
  # responds to `size`. Adds the error
  # `"<field> is too long. It must be at most <length>"` on failure. For
  # nil-safe checks with custom messages/contexts/ranges, use
  # `validates_length_of`.
  #
  # ```
  # class Post < Grant::Base
  #   column id : Int64, primary: true
  #   column title : String = ""
  #   validate_max_length :title, 120
  # end
  #
  # Post.new(title: "A reasonable title").valid? # => true
  # Post.new(title: "x" * 200).valid?            # => false
  # ```
  macro validate_max_length(field, length)
    validate {{field}}, "#{{{field}}} is too long. It must be at most #{{{length}}}", Proc(self, Bool).new { |model| (model.{{field.id}}.not_nil!.size <= {{length.id}}) }
  end
end
