require "yaml"
require "../decimal"

# YAML for `Grant::Mica::Decimal128` (opt-in: `require "mica/decimal/yaml"`).
#
# A value is written as a plain scalar in its plain form (`12.30`) and read
# from any scalar's text, so the digits and scale survive the round trip.
#
# ```
# Grant::Mica::Decimal128.parse("12.30").to_yaml   # => "--- 12.30\n"
# Grant::Mica::Decimal128.from_yaml("12.30").scale # => 2
# ```
module Grant::Mica
  struct Decimal128
    # Reads a scalar. Raises `YAML::ParseException` for any other node and
    # for text that is not a decimal of up to 38 digits.
    def self.new(context : ::YAML::ParseContext, node : ::YAML::Nodes::Node) : Decimal128
      unless node.is_a?(::YAML::Nodes::Scalar)
        node.raise "Expected a decimal scalar, not #{node.kind}"
      end
      parse?(node.value) || node.raise "Expected a decimal of up to #{MAX_DIGITS} digits, not #{node.value.inspect}"
    end

    # Writes the plain form as a plain scalar.
    def to_yaml(yaml : ::YAML::Nodes::Builder) : Nil
      yaml.scalar(to_s)
    end
  end
end
