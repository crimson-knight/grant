# Patterns that use lookaround or a possessive quantifier compile on PCRE2
# and not on Mica, the default `Regex` engine of crystal-alpha from
# 1.21.0-incremental-6. Grant ships none; the specs keep the ones Grant used
# to ship as the reference its rewrites are compared with.
#
# A literal Mica cannot run stops the compile, so these are built at run
# time: `compile?` returns the pattern where the engine runs it and nil
# where it does not.
module PCRE2OnlyPattern
  def self.compile?(source : String, options : Regex::Options = Regex::Options::None) : Regex?
    Regex.new(source, options)
  rescue ArgumentError
    nil
  end

  # Builds, without lookahead, a pattern that matches every text that does
  # not start with *prefix*: at each character of the prefix the text ends,
  # differs, or goes on to the next character.
  def self.not_starting_with(prefix : String) : Regex
    source = prefix.chars.reverse!.reduce("") do |rest_of_prefix, char|
      escaped = Regex.escape(char.to_s)
      rest_of_prefix.empty? ? "(?:\\z|[^#{escaped}])" : "(?:\\z|[^#{escaped}]|#{escaped}#{rest_of_prefix})"
    end
    Regex.new("\\A#{source}")
  end
end
