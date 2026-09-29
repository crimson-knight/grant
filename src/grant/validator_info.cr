require "./error"

# What a model knows about one of its validators, for form builders, API
# documentation and tooling (ActiveModel's `validators_on`).
#
# ```
# User.validators_on(:name).each do |info|
#   info.kind         # => :length
#   info.attribute    # => "name"
#   info.options      # => {:maximum => 40}
#   info.contexts     # => [:save]
#   info.conditional? # => false (no if: / unless:)
# end
# ```
#
# The records are built once, when the validator is declared; reading them
# allocates nothing but the array that holds them.
struct Grant::ValidatorInfo
  # The validator: `:presence`, `:absence`, `:length`, `:numericality`,
  # `:format`, `:inclusion`, `:exclusion`, `:comparison`, `:confirmation`,
  # `:acceptance`, `:uniqueness`, `:associated`, `:with` (`validates_with`),
  # `:each` (`validates_each`), `:method` (`validate :name`) or `:custom`
  # (`validate` with a block).
  getter kind : Symbol

  # The attribute it validates (`"base"` for record-level validators).
  getter attribute : String

  # The options it was declared with (`maximum:`, `greater_than:`,
  # `allow_nil:`...). Conditions (`if:`, `unless:`, `on:`) and `strict:` are
  # not among them; values that are not simple data (Regex, Range of other
  # types, lambdas) are kept as their `to_s`.
  getter options : Grant::Error::Options

  # The validation contexts it runs in (`[:save]` = always).
  getter contexts : Array(Symbol)

  # True when it has an `if:` or `unless:` condition.
  getter? conditional : Bool

  def initialize(@kind : Symbol, @attribute : String, @options : Grant::Error::Options, @contexts : Array(Symbol), @conditional : Bool = false)
  end

  # The option *key*, or nil.
  def option(key : Symbol) : Grant::Error::Value
    @options[key]?
  end

  # True when this validator makes the attribute required
  # (`validates_presence_of`, without `allow_nil` / `allow_blank`).
  def required? : Bool
    @kind == :presence && !@conditional && !@options[:allow_nil]? && !@options[:allow_blank]?
  end
end
