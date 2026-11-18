module Grant
  # A `filter_attributes` entry that filters the column names its Regex
  # matches. `filter_attributes /secret/i` in a model builds one.
  class RegexAttributeNamePattern < AttributeNamePattern
    getter regex : Regex

    def initialize(@regex : Regex)
    end

    def matches?(name : String) : Bool
      @regex.matches?(name)
    end

    def_equals_and_hash @regex
  end

  class Settings
    # Sets `filter_attributes` from names and Regex patterns, as Grant 0.23
    # accepted them.
    #
    # ```
    # Grant.settings.filter_attributes = ["password", /\Atoken/] of String | Regex
    # ```
    def filter_attributes=(entries : Array(String | Regex)) : Array(String | Regex)
      self.filter_attributes = entries.map do |entry|
        entry.is_a?(Regex) ? RegexAttributeNamePattern.new(entry).as(AttributeFilter) : entry.as(AttributeFilter)
      end
      entries
    end
  end
end
