require "./character_class_data"

# :nodoc:
#
# The character classes of a Crystal `Regex`, answered without PCRE2. Crystal
# compiles every regex with UTF and UCP, so `\w`, `\d` and `\s` are Unicode
# classes and a case-insensitive ASCII letter also matches a few non-ASCII
# letters (the Kelvin sign matches `k`, the long s matches `s`).
#
# The answers follow the PCRE2 10.43+ Unicode tables in
# `character_class_data.cr` on every platform, whatever PCRE2 the system has:
# `\w` is a letter, a number, a nonspacing mark or a connector punctuation.
# `scripts/generate_character_classes.cr` writes the tables from a linked
# PCRE2 10.43 or later; `spec/grant/text/character_class_spec.cr` checks every
# code point against PCRE2 where the linked one is 10.43 or later, and checks
# the tables themselves everywhere.
module Grant::CharacterClass
  # `\w`: a letter, a number, a nonspacing mark or a connector punctuation.
  def self.word?(char : Char) : Bool
    return char.ascii_alphanumeric? || char == '_' if char.ascii?
    in_ranges?(char, WORD_RANGES)
  end

  # `\d`: a decimal digit in any script.
  def self.digit?(char : Char) : Bool
    return char.ascii_number? if char.ascii?
    in_ranges?(char, DIGIT_RANGES)
  end

  # `\s`: Unicode white space, including the line and paragraph separators.
  def self.space?(char : Char) : Bool
    return char == ' ' || '\t' <= char <= '\r' if char.ascii?
    in_ranges?(char, SPACE_RANGES)
  end

  # Whether *char* matches the lowercase ASCII *letter* in a case-insensitive
  # regex.
  def self.letter_ignoring_case?(char : Char, letter : Char) : Bool
    return char.downcase == letter if char.ascii?
    non_ascii_letter_fold(char) == letter
  end

  # Whether *char* matches `[A-Za-z]` (or `[a-z]`) in a case-insensitive regex.
  def self.ascii_letter_ignoring_case?(char : Char) : Bool
    return char.ascii_letter? if char.ascii?
    !non_ascii_letter_fold(char).nil?
  end

  # Whether `\b` holds between *before* and *after* (`nil` is the edge of the
  # text).
  def self.word_boundary?(before : Char?, after : Char?) : Bool
    before_is_word = before ? word?(before) : false
    after_is_word = after ? word?(after) : false
    before_is_word != after_is_word
  end

  # The ASCII letter a case-insensitive regex matches against the non-ASCII
  # *char*, or `nil` when it matches none.
  private def self.non_ascii_letter_fold(char : Char) : Char?
    code = char.ord.to_u32!
    folds = NON_ASCII_LETTER_FOLDS
    index = first_pair_reaching(folds, code, column: 0)
    return unless index < folds.size && folds.unsafe_fetch(index) == code
    folds.unsafe_fetch(index + 1).chr
  end

  # Whether *char* lies in one of the inclusive `first, last` pairs of
  # *ranges*.
  private def self.in_ranges?(char : Char, ranges : Slice(UInt32)) : Bool
    code = char.ord.to_u32!
    index = first_pair_reaching(ranges, code, column: 1)
    index < ranges.size && ranges.unsafe_fetch(index) <= code
  end

  # The slice index of the first pair in *table* whose entry in *column*
  # (0 or 1) is at least *code*, or `table.size` when no pair reaches it. The
  # pairs are sorted, so this is a binary search.
  private def self.first_pair_reaching(table : Slice(UInt32), code : UInt32, column : Int32) : Int32
    low = 0
    high = table.size // 2
    while low < high
      middle = (low + high) // 2
      if table.unsafe_fetch(2 * middle + column) < code
        low = middle + 1
      else
        high = middle
      end
    end
    2 * low
  end
end
