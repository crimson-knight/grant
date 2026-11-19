require "../../spec_helper"
require "../../support/linked_pcre2"

# Grant's `\w`, `\d` and `\s` follow the PCRE2 10.43+ tables in
# `src/grant/text/character_class_data.cr` on every platform. Where the linked
# PCRE2 is 10.43 or later, every code point is checked against it; a failure
# there means the tables are stale: rerun `scripts/generate_character_classes.cr`.
private def each_code_point(& : Char ->) : Nil
  (0..0x10FFFF).each do |code|
    next if 0xD800 <= code <= 0xDFFF
    yield code.chr
  end
end

# A packed table (consecutive `first, last` entries) as an array of pairs.
private def pairs_of(table : Slice(UInt32)) : Array({Int32, Int32})
  table.each_slice(2).map { |(first, last)| {first.to_i, last.to_i} }.to_a
end

# The problems with a range table: ranges out of order, overlapping or touching
# (the generator merges neighbors), reversed, outside Unicode, or holding
# surrogates.
private def range_table_problems(ranges : Array({Int32, Int32})) : Array(String)
  problems = [] of String
  previous_last = -2
  ranges.each do |(first, last)|
    label = "#{first.to_s(16)}..#{last.to_s(16)}"
    problems << "#{label} is reversed" if first > last
    problems << "#{label} overlaps or touches the range before it" if first <= previous_last + 1
    problems << "#{label} lies outside Unicode" if first < 0 || last > 0x10FFFF
    problems << "#{label} holds surrogates" if first <= 0xDFFF && last >= 0xD800
    previous_last = last
  end
  problems
end

private def in_table?(ranges : Array({Int32, Int32}), code : Int32) : Bool
  ranges.any? { |(first, last)| first <= code <= last }
end

describe Grant::CharacterClass do
  describe "its PCRE2 10.43+ tables" do
    it "hold sorted, separate ranges of Unicode scalar values" do
      {
        "word"  => pairs_of(Grant::CharacterClass.word_ranges),
        "digit" => pairs_of(Grant::CharacterClass.digit_ranges),
        "space" => pairs_of(Grant::CharacterClass.space_ranges),
      }.each do |name, ranges|
        ranges.should_not be_empty
        range_table_problems(ranges).map { |problem| "#{name}: #{problem}" }.should be_empty
      end
    end

    it "are packed read-only data" do
      {
        Grant::CharacterClass.word_ranges,
        Grant::CharacterClass.digit_ranges,
        Grant::CharacterClass.space_ranges,
        Grant::CharacterClass.non_ascii_letter_folds,
      }.each do |table|
        table.read_only?.should be_true
        table.size.even?.should be_true
      end
    end

    it "agree with the ASCII answers" do
      word_ranges = pairs_of(Grant::CharacterClass.word_ranges)
      digit_ranges = pairs_of(Grant::CharacterClass.digit_ranges)
      space_ranges = pairs_of(Grant::CharacterClass.space_ranges)
      (0..0x7F).each do |code|
        char = code.chr
        in_table?(word_ranges, code).should eq(char.ascii_alphanumeric? || char == '_')
        in_table?(digit_ranges, code).should eq(char.ascii_number?)
        in_table?(space_ranges, code).should eq(char == ' ' || '\t' <= char <= '\r')
      end
    end

    it "answer every non-ASCII range edge as the table holds it" do
      {
        Grant::CharacterClass.word_ranges  => ->Grant::CharacterClass.word?(Char),
        Grant::CharacterClass.digit_ranges => ->Grant::CharacterClass.digit?(Char),
        Grant::CharacterClass.space_ranges => ->Grant::CharacterClass.space?(Char),
      }.each do |table, class_answer|
        ranges = pairs_of(table)
        ranges.each do |(first, last)|
          {first - 1, first, last, last + 1}.each do |code|
            next if code < 0x80 || 0xD800 <= code <= 0xDFFF || code > 0x10FFFF
            class_answer.call(code.chr).should eq(in_table?(ranges, code))
          end
        end
      end
    end

    it "count every digit as a word character and no space as one" do
      pairs_of(Grant::CharacterClass.digit_ranges).each do |(first, last)|
        (first..last).each { |code| Grant::CharacterClass.word?(code.chr).should be_true }
      end
      pairs_of(Grant::CharacterClass.space_ranges).each do |(first, last)|
        (first..last).each { |code| Grant::CharacterClass.word?(code.chr).should be_false }
      end
    end

    it "put nonspacing marks and connector punctuation in \\w" do
      # Combining acute accent, Hebrew point sheva, undertie, presentation
      # form low line: PCRE2 10.43 added these to \w.
      ['\u{301}', '\u{5B0}', '\u{203F}', '\u{FE4F}'].each do |char|
        Grant::CharacterClass.word?(char).should be_true
      end
      # Spacing and enclosing marks, dash and other punctuation stay out.
      ['\u{903}', '\u{20DD}', '-', '\u{2010}', '.', '\u{B7}'].each do |char|
        Grant::CharacterClass.word?(char).should be_false
      end
    end

    it "answer \\w, \\d and \\s for letters, digits and spaces in other scripts" do
      ['é', '\u{212A}', 'ſ', 'ı', 'İ', '漢', '\u{10400}'].each { |char| Grant::CharacterClass.word?(char).should be_true }
      ['٣', '۵', '\u{7C1}', '१', '\u{FF10}', '\u{1D7CE}', '\u{1E4F0}'].each { |char| Grant::CharacterClass.digit?(char).should be_true }
      ['\u{216B}', '½', '²', 'a', '😀'].each { |char| Grant::CharacterClass.digit?(char).should be_false }
      ['\u0085', '\u{A0}', '\u{1680}', '\u{2003}', '\u{2028}', '\u{2029}', '\u{202F}', '\u{205F}', '\u{3000}'].each do |char|
        Grant::CharacterClass.space?(char).should be_true
      end
      ['\u{200B}', '\u{FEFF}', 'a', '_'].each { |char| Grant::CharacterClass.space?(char).should be_false }
    end

    it "fold only the Kelvin sign and the long s onto ASCII letters" do
      pairs_of(Grant::CharacterClass.non_ascii_letter_folds).should eq([{'ſ'.ord, 's'.ord}, {'\u{212A}'.ord, 'k'.ord}])
      Grant::CharacterClass.letter_ignoring_case?('\u{212A}', 'k').should be_true
      Grant::CharacterClass.letter_ignoring_case?('ſ', 's').should be_true
      Grant::CharacterClass.letter_ignoring_case?('ı', 'i').should be_false
      Grant::CharacterClass.ascii_letter_ignoring_case?('İ').should be_false
    end
  end

  if LinkedPCRE2.follows_grant_tables?
    it "answers \\w, \\d and \\s exactly as a Crystal regex does for every code point" do
      mismatches = [] of String
      each_code_point do |char|
        text = char.to_s
        mismatches << "word #{char.ord.to_s(16)}" unless Grant::CharacterClass.word?(char) == text.matches?(LinkedPCRE2::WORD)
        mismatches << "digit #{char.ord.to_s(16)}" unless Grant::CharacterClass.digit?(char) == text.matches?(LinkedPCRE2::DIGIT)
        mismatches << "space #{char.ord.to_s(16)}" unless Grant::CharacterClass.space?(char) == text.matches?(LinkedPCRE2::SPACE)
      end
      mismatches.should be_empty
    end

    it "folds ASCII letters as a case-insensitive regex does for every code point" do
      letters = ('a'..'z').to_a
      patterns = letters.map { |letter| Regex.new("\\A#{letter}\\z", :ignore_case) }
      mismatches = [] of String
      each_code_point do |char|
        text = char.to_s
        letters.each_with_index do |letter, index|
          expected = text.matches?(patterns[index])
          mismatches << "#{letter} #{char.ord.to_s(16)}" unless Grant::CharacterClass.letter_ignoring_case?(char, letter) == expected
        end
        unless Grant::CharacterClass.ascii_letter_ignoring_case?(char) == text.matches?(LinkedPCRE2::LETTERS)
          mismatches << "[a-z] #{char.ord.to_s(16)}"
        end
      end
      mismatches.should be_empty
    end
  else
    pending "answers \\w, \\d and \\s exactly as a Crystal regex does for every code point (#{LinkedPCRE2::PENDING_REASON})"
    pending "folds ASCII letters as a case-insensitive regex does for every code point (#{LinkedPCRE2::PENDING_REASON})"
  end

  it "places \\b where a regex does" do
    samples = ['a', '_', '1', ' ', '.', 'é', '\u{301}', '\u{212A}', '-', '\u{A0}'].select { |char| LinkedPCRE2.agrees_on_char?(char) }
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
