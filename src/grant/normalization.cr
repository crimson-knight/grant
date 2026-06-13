# Canonicalizes attribute values before validation, in the style of Rails'
# `normalizes`.
#
# Declaring `normalizes :email { |value| value.downcase.strip }` registers a
# transform that runs in a `before_validation` hook: whenever the model is
# validated or saved, the block rewrites the attribute in place. This keeps stored
# data canonical (lower-cased emails, digit-only phone numbers, trimmed names)
# without scattering the logic across callers.
#
# The block runs only when the attribute is a non-nil `String`. To install the
# `before_validation` hook, the model must **`include Grant::Normalization`**
# (the `normalizes` macro itself is available on every `Grant::Base`, but the hook
# that runs the transforms comes from including this module).
#
# ```
# class User < Grant::Base
#   include Grant::Normalization
#   column id : Int64, primary: true
#   column email : String?
#   column phone : String?
#
#   normalizes :email do |value|
#     value.downcase.strip
#   end
#
#   normalizes :phone do |value|
#     value.gsub(/\D/, "") # strip non-digits
#   end
# end
#
# u = User.new
# u.email = "  Alice@Example.COM "
# u.valid? # runs normalizations
# u.email  # => "alice@example.com"
# ```
module Grant::Normalization
  macro included
    before_validation :_run_normalizations
    
    # Generate instance method that calls all normalization methods
    private def _run_normalizations
      # Check if normalization should be skipped
      return if @_skip_normalization
      
      {% verbatim do %}
        {% for method in @type.methods %}
          {% if method.name.starts_with?("_normalize_") && method.visibility == :private %}
            {{ method.name.id }}
          {% end %}
        {% end %}
      {% end %}
    end
  end

  # Registers a normalization for *attribute*: the block's result replaces the
  # attribute's value before each validation.
  #
  # The block receives the current value (bound as `value`) and must return the
  # normalized value; it runs only when the attribute is a non-nil `String`. A
  # block is required. Pass `if:` with a predicate method name (a `Symbol`) to run
  # the normalization conditionally.
  #
  # Generates a private `_normalize_<attribute>` method that the module's
  # `before_validation` hook invokes — so the enclosing model must
  # `include Grant::Normalization` for it to fire.
  #
  # ```
  # class User < Grant::Base
  #   include Grant::Normalization
  #   column id : Int64, primary: true
  #   column email : String?
  #   column website : String?
  #
  #   normalizes :email do |value|
  #     value.downcase.strip
  #   end
  #
  #   # conditional: only when website_present? returns true
  #   normalizes :website, if: :website_present? do |value|
  #     value.starts_with?("http") ? value : "https://#{value}"
  #   end
  #
  #   def website_present?
  #     !website.try(&.empty?)
  #   end
  # end
  # ```
  macro normalizes(attribute, **options, &block)
    {% if block %}
      {% attribute_name = attribute.id %}
      {% method_name = "_normalize_#{attribute_name}".id %}
      
      # Generate normalization method
      private def {{ method_name }}
        {% if options[:if] %}
          return unless {{ options[:if].id }}
        {% end %}
        
        if value = self.{{ attribute_name }}
          if value.is_a?(String)
            normalized = begin
              {{ block.body }}
            end
            self.{{ attribute_name }} = normalized
          end
        end
      end
    {% else %}
      {% raise "normalizes requires a block" %}
    {% end %}
  end
end
