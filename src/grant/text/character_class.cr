require "./character_class_data"

# :nodoc:
#
# The character classes of a Crystal `Regex`, answered without PCRE2. Crystal
# compiles every regex with UTF and UCP, so `\w`, `\d` and `\s` are Unicode
# classes and a case-insensitive ASCII letter also matches a few non-ASCII
# letters (the Kelvin sign matches `k`, the long s matches `s`). The tables in
# `character_class_data.cr` are generated from the linked PCRE2 by
# `scripts/generate_character_classes.cr`; `spec/grant/text/character_class_spec.cr`
# checks every code point against PCRE2.
module Grant::CharacterClass
  # `\w`: a letter, a number, a nonspacing mark or a connector punctuation.
  def self.word?(char : Char) : Bool
    return char.ascii_alphanumeric? || char == '_' if char.ascii?
    in_ranges?(char, word_ranges)
  end

  # `\d`: a decimal digit in any script.
  def self.digit?(char : Char) : Bool
    return char.ascii_number? if char.ascii?
    in_ranges?(char, digit_ranges)
  end

  # `\s`: Unicode white space, including the line and paragraph separators.
  def self.space?(char : Char) : Bool
    return char == ' ' || '\t' <= char <= '\r' if char.ascii?
    in_ranges?(char, space_ranges)
  end

  # Whether *char* matches the lowercase ASCII *letter* in a case-insensitive
  # regex.
  def self.letter_ignoring_case?(char : Char, letter : Char) : Bool
    return char.downcase == letter if char.ascii?
    non_ascii_letter_folds[char]? == letter
  end

  # Whether *char* matches `[A-Za-z]` (or `[a-z]`) in a case-insensitive regex.
  def self.ascii_letter_ignoring_case?(char : Char) : Bool
    return char.ascii_letter? if char.ascii?
    non_ascii_letter_folds.has_key?(char)
  end

  # Whether `\b` holds between *before* and *after* (`nil` is the edge of the
  # text).
  def self.word_boundary?(before : Char?, after : Char?) : Bool
    before_is_word = before ? word?(before) : false
    after_is_word = after ? word?(after) : false
    before_is_word != after_is_word
  end

  private def self.in_ranges?(char : Char, ranges : Array({Int32, Int32})) : Bool
    code = char.ord
    range = ranges.bsearch { |candidate| candidate[1] >= code }
    !range.nil? && range[0] <= code
  end
end
