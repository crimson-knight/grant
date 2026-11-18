# Grant's `\w`, `\d` and `\s` follow the PCRE2 10.43+ Unicode tables checked
# in as `src/grant/text/character_class_data.cr`, on every platform. The specs
# that compare Grant with the PCRE2 that Crystal links use this module to
# compare only where that PCRE2 gives the same answers: PCRE2 10.42 (Ubuntu
# 24.04) leaves nonspacing marks and connector punctuation out of `\w` and
# carries an older Unicode version.
module LinkedPCRE2
  WORD    = /\A\w\z/
  DIGIT   = /\A\d\z/
  SPACE   = /\A\s\z/
  LETTERS = /\A[a-z]\z/i

  PENDING_REASON = "the linked PCRE2 predates 10.43: its \\w leaves out the nonspacing marks and connector punctuation that Grant's 10.43+ tables include"

  # Whether the linked PCRE2 has the 10.43+ `\w`: a combining acute accent
  # (U+0301, a nonspacing mark) and an undertie (U+203F, a connector
  # punctuation) are word characters.
  class_getter? follows_grant_tables : Bool = "\u{301}".matches?(WORD) && "\u{203F}".matches?(WORD)

  # Whether the linked PCRE2 and `Grant::CharacterClass` agree on every
  # character of *text*.
  def self.agrees_on?(text : String) : Bool
    return true if follows_grant_tables?
    text.each_char.all? { |char| agrees_on_char?(char) }
  end

  # Whether the linked PCRE2 and `Grant::CharacterClass` give *char* the same
  # `\w`, `\d`, `\s` and case-insensitive ASCII letter answers.
  def self.agrees_on_char?(char : Char) : Bool
    text = char.to_s
    Grant::CharacterClass.word?(char) == text.matches?(WORD) &&
      Grant::CharacterClass.digit?(char) == text.matches?(DIGIT) &&
      Grant::CharacterClass.space?(char) == text.matches?(SPACE) &&
      Grant::CharacterClass.ascii_letter_ignoring_case?(char) == text.matches?(LETTERS)
  end
end
