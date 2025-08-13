require "./error"

# Analyze validation blocks and procs
#
# By example:
# ```
# validate :name, "can't be blank" do |user|
#   !user.name.to_s.blank?
# end
#
# validate :name, "can't be blank", ->(user : User) do
#   !user.name.to_s.blank?
# end
#
# name_required = ->(model : Grant::Base) { !model.name.to_s.blank? }
# validate :name, "can't be blank", name_required
# ```
module Grant::Validators
  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]

  # Returns all errors on the model.
  getter errors = [] of Error

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @_skip_normalization : Bool = false

  macro included
    macro inherited
      @@validators = Array({field: String, message: String, block: Proc(self, Bool)}).new

      disable_grant_docs? def self.validate(message : String, &block : self -> Bool)
        self.validate(:base, message, block)
      end

      disable_grant_docs? def self.validate(field : (Symbol | String), message : String, &block : self -> Bool)
        self.validate(field, message, block)
      end

      disable_grant_docs? def self.validate(message : String, block : self -> Bool)
        self.validate(:base, message, block)
      end

      disable_grant_docs? def self.validate(field : (Symbol | String), message : String, block : self -> Bool)
        @@validators << {field: field.to_s, message: message, block: block}
      end
    end
  end

  # Runs all of `self`'s validators, returning `true` if they all pass, and `false`
  # otherwise.
  #
  # If the validation fails, `#errors` will contain all the errors responsible for
  # the failing.
  def valid?(skip_normalization : Bool = false)
    # Return false if any `ConversionError` were added
    # when setting model properties
    return false if errors.any? ConversionError

    errors.clear

    # Set flag for normalization to check
    @_skip_normalization = skip_normalization

    # Run before_validation callbacks
    before_validation if responds_to?(:before_validation)

    @@validators.each do |validator|
      unless validator[:block].call(self)
        errors << Error.new(validator[:field], validator[:message])
      end
    end

    # Run after_validation callbacks
    after_validation if responds_to?(:after_validation)

    # Reset the flag
    @_skip_normalization = false

    errors.empty?
  end
end
