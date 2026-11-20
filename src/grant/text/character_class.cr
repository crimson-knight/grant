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
  # `word?`, `digit?` and `space?` stay out of line, as they were when their
  # tables were built on first use: inlined into the many `CharacterScan`
  # callers, they shift what the inliner pulls into the single-byte paths of
  # `Grant::TextMatching`, and those paths slow down by up to 1.6x. Inside
  # each, the table search inlines with a constant address and size.

  # `\w`: a letter, a number, a nonspacing mark or a connector punctuation.
  @[NoInline]
  def self.word?(char : Char) : Bool
    return char.ascii_alphanumeric? || char == '_' if char.ascii?
    in_ranges?(char, word_ranges)
  end

  # `\d`: a decimal digit in any script.
  @[NoInline]
  def self.digit?(char : Char) : Bool
    return char.ascii_number? if char.ascii?
    in_ranges?(char, digit_ranges)
  end

  # `\s`: Unicode white space, including the line and paragraph separators.
  @[NoInline]
  def self.space?(char : Char) : Bool
    return char == ' ' || '\t' <= char <= '\r' if char.ascii?
    in_ranges?(char, space_ranges)
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
    folds = non_ascii_letter_folds
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
  # pairs are sorted, so this is a binary search; each step picks the next
  # base with a conditional move rather than a branch the CPU must predict.
  private def self.first_pair_reaching(table : Slice(UInt32), code : UInt32, column : Int32) : Int32
    base = 0
    length = table.size // 2
    return 0 if length == 0
    while length > 1
      half = length // 2
      base = table.unsafe_fetch(2 * (base + half) + column) < code ? base + half : base
      length -= half
    end
    base += 1 if table.unsafe_fetch(2 * base + column) < code
    2 * base
  end
end
