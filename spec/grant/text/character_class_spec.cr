require "../../spec_helper"

# Every code point, checked against the PCRE2 that Crystal's `Regex` links. A
# failure here means the generated tables are stale: rerun
# `scripts/generate_character_classes.cr`.
private def each_code_point(& : Char ->) : Nil
  (0..0x10FFFF).each do |code|
    next if 0xD800 <= code <= 0xDFFF
    yield code.chr
  end
end

describe Grant::CharacterClass do
  it "answers \\w, \\d and \\s exactly as a Crystal regex does for every code point" do
    word = /\A\w\z/
    digit = /\A\d\z/
    space = /\A\s\z/
    mismatches = [] of String
    each_code_point do |char|
      text = char.to_s
      mismatches << "word #{char.ord.to_s(16)}" unless Grant::CharacterClass.word?(char) == text.matches?(word)
      mismatches << "digit #{char.ord.to_s(16)}" unless Grant::CharacterClass.digit?(char) == text.matches?(digit)
      mismatches << "space #{char.ord.to_s(16)}" unless Grant::CharacterClass.space?(char) == text.matches?(space)
    end
    mismatches.should be_empty
  end

  it "folds ASCII letters as a case-insensitive regex does for every code point" do
    letters = ('a'..'z').to_a
    patterns = letters.map { |letter| Regex.new("\\A#{letter}\\z", :ignore_case) }
    class_pattern = /\A[a-z]\z/i
    mismatches = [] of String
    each_code_point do |char|
      text = char.to_s
      letters.each_with_index do |letter, index|
        expected = text.matches?(patterns[index])
        mismatches << "#{letter} #{char.ord.to_s(16)}" unless Grant::CharacterClass.letter_ignoring_case?(char, letter) == expected
      end
      unless Grant::CharacterClass.ascii_letter_ignoring_case?(char) == text.matches?(class_pattern)
        mismatches << "[a-z] #{char.ord.to_s(16)}"
      end
    end
    mismatches.should be_empty
  end

  it "places \\b where a regex does" do
    samples = ['a', '_', '1', ' ', '.', 'é', '́', 'K', '-', ' ']
    samples.each do |before|
      samples.each do |after|
        expected = "#{before}#{after}".matches?(/\A.\b./)
        Grant::CharacterClass.word_boundary?(before, after).should eq(expected)
      end
      Grant::CharacterClass.word_boundary?(nil, before).should eq(before.to_s.matches?(/\A\b/))
      Grant::CharacterClass.word_boundary?(before, nil).should eq(before.to_s.matches?(/\b\z/))
    end
  end
end
