module Grant
  # A pattern that `filter_attributes` matches column names against, besides a
  # plain String (a case-insensitive substring). `require "grant/regex"` adds
  # `Grant::RegexAttributeNamePattern`, which matches with a `Regex`.
  abstract class AttributeNamePattern
    # Whether column *name* is filtered.
    abstract def matches?(name : String) : Bool
  end

  # One `filter_attributes` entry: a name matched as a case-insensitive
  # substring, or an `AttributeNamePattern`.
  alias AttributeFilter = String | AttributeNamePattern
end
