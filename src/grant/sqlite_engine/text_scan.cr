module Grant::SQLiteEngine
  # :nodoc:
  #
  # Byte scanners over SQL text and number text, written by hand so the
  # engine reaches no `Regex` and an app on it links no PCRE2.
  #
  # Each scanner reads the ASCII part of its input exactly as the regex it
  # replaced: whitespace is space, tab, LF, VT, FF and CR, digits are `0-9`,
  # and case-insensitive matching folds ASCII letters. Outside ASCII they
  # follow SQLite's tokenizer, which the regexes approximated: every byte of
  # a multibyte UTF-8 character continues a word (as a Unicode letter does
  # for the regex's `\b` and `\W`), and none is a digit or whitespace.
  module TextScan
    # Which bytes continue a word on either side of a whole-word match.
    enum WordBytes
      # `[A-Za-z0-9_]` and every byte of a non-ASCII character: the `\w`
      # behind `\b` and `\W`.
      Word
      # `[A-Za-z0-9_$]` only, the explicit ASCII class of an identifier
      # match: a `$` continues the name and a non-ASCII byte ends it.
      AsciiIdentifier
    end

    # Whether *byte* continues a word under *word_bytes*.
    def self.word_byte?(byte : UInt8, word_bytes : WordBytes = WordBytes::Word) : Bool
      return true if byte.unsafe_chr.ascii_alphanumeric? || byte === '_'
      word_bytes.word? ? byte >= 0x80 : byte === '$'
    end

    # Whether *byte* is ASCII whitespace (`\s` over ASCII).
    def self.whitespace_byte?(byte : UInt8) : Bool
      byte === ' ' || (0x09_u8..0x0d_u8).includes?(byte)
    end

    # Whether *byte* is an ASCII decimal digit.
    def self.digit_byte?(byte : UInt8) : Bool
      byte.unsafe_chr.ascii_number?
    end

    # Whether *text* contains *word* with no word byte (see `WordBytes`)
    # touching it on either side, so `contains_word?("x IN (SELECT 1)",
    # "SELECT")` is true and `contains_word?("selected", "SELECT")` is
    # false. With *case_insensitive*, ASCII letters match in either case.
    #
    # Under `WordBytes::Word`, for a *word* that starts and ends with word
    # bytes this is `/\bword\b/`; for any *word* it is
    # `/(?:^|\W)word(?:\W|$)/`.
    def self.contains_word?(text : String, word : String, *, case_insensitive : Bool = true,
                            word_bytes : WordBytes = WordBytes::Word) : Bool
      bytes = text.to_slice
      pattern = word.to_slice
      return false if pattern.size > bytes.size
      (0..bytes.size - pattern.size).any? do |start|
        next false if start > 0 && word_byte?(bytes[start - 1], word_bytes)
        finish = start + pattern.size
        next false if finish < bytes.size && word_byte?(bytes[finish], word_bytes)
        same_bytes?(bytes, start, pattern, case_insensitive)
      end
    end

    # Whether *text* contains any of *words* as a whole word, ignoring
    # ASCII case (`/\b(LIKE|GLOB)\b/i`).
    def self.contains_any_word?(text : String, words : Enumerable(String)) : Bool
      words.any? { |word| contains_word?(text, word) }
    end

    # Whether *text* contains *fragment* anywhere, ignoring ASCII case
    # (`/fragment/i`).
    def self.contains_ignoring_case?(text : String, fragment : String) : Bool
      bytes = text.to_slice
      pattern = fragment.to_slice
      return false if pattern.size > bytes.size
      (0..bytes.size - pattern.size).any? { |start| same_bytes?(bytes, start, pattern, true) }
    end

    # *text* with every single-quoted SQL string, doubled quotes included,
    # replaced by `''` (`text.gsub(/'(?:[^']|'')*'/, "''")`).
    #
    # A string left open at the end of *text* ends, as the regex's
    # backtracking ends it, at the first quote of its last doubled pair,
    # and stays as it is when it has no doubled pair.
    def self.blank_quoted_strings(text : String) : String
      bytes = text.to_slice
      String.build(bytes.size) do |io|
        position = 0
        copied = 0
        while position < bytes.size
          unless bytes[position] === '\''
            position += 1
            next
          end
          if finish = quoted_string_end(bytes, position)
            io.write(bytes[copied, position - copied])
            io << "''"
            position = copied = finish
          else
            position += 1
          end
        end
        io.write(bytes[copied, bytes.size - copied])
      end
    end

    # Yields each name written before an opening parenthesis, left to
    # right, as `text.scan(/([A-Za-z_][A-Za-z0-9_$]*)\s*\(/)` captures them:
    # `count (x)` yields `count`, `t1.f(x)` yields `f`, and `9e(x)` yields
    # `e` (a name starts at the first letter or underscore).
    def self.each_function_name(text : String, & : String ->) : Nil
      bytes = text.to_slice
      position = 0
      while position < bytes.size
        byte = bytes[position]
        unless byte.unsafe_chr.ascii_letter? || byte === '_'
          position += 1
          next
        end
        name_end = position + 1
        while name_end < bytes.size && word_byte?(bytes[name_end], WordBytes::AsciiIdentifier)
          name_end += 1
        end
        after = name_end
        while after < bytes.size && whitespace_byte?(bytes[after])
          after += 1
        end
        if after < bytes.size && bytes[after] === '('
          yield String.new(bytes[position, name_end - position])
          position = after + 1
        else
          # A later start inside the same name ends where this one did and
          # fails the same way.
          position = name_end
        end
      end
    end

    # The index just past the decimal mantissa that starts at *start*
    # (`\d+\.?\d*|\.\d+`, greedy), or nil when none starts there.
    def self.mantissa_end(bytes : Bytes, start : Int32) : Int32?
      position = digits_end(bytes, start)
      if position > start
        position += 1 if position < bytes.size && bytes[position] === '.'
        return digits_end(bytes, position)
      end
      return unless position < bytes.size && bytes[position] === '.'
      fraction_end = digits_end(bytes, position + 1)
      fraction_end > position + 1 ? fraction_end : nil
    end

    # The index just past the exponent that starts at *start*
    # (`[eE][+-]?\d+`, greedy), or nil when none starts there.
    def self.exponent_end(bytes : Bytes, start : Int32) : Int32?
      return unless start < bytes.size && (bytes[start] === 'e' || bytes[start] === 'E')
      digits_start = sign_end(bytes, start + 1)
      finish = digits_end(bytes, digits_start)
      finish > digits_start ? finish : nil
    end

    # *start*, or one past it when a `+` or `-` sits there.
    def self.sign_end(bytes : Bytes, start : Int32) : Int32
      start < bytes.size && (bytes[start] === '+' || bytes[start] === '-') ? start + 1 : start
    end

    # The index just past the run of ASCII digits that starts at *start*
    # (*start* itself when no digit is there).
    def self.digits_end(bytes : Bytes, start : Int32) : Int32
      position = start
      while position < bytes.size && digit_byte?(bytes[position])
        position += 1
      end
      position
    end

    # Whether all of *text* is a decimal number with an optional sign,
    # fraction and exponent (`/\A[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?\z/`).
    def self.decimal_number?(text : String) : Bool
      bytes = text.to_slice
      finish = mantissa_end(bytes, sign_end(bytes, 0))
      return false unless finish
      finish = exponent_end(bytes, finish) || finish
      finish == bytes.size
    end

    # The condition of a partial index: the text after the first `WHERE`
    # (any case) with whitespace on both sides in *create_sql*, stripped
    # (`create_sql[/\sWHERE\s+(.*)\z/mi, 1]?.try(&.strip)`), or nil.
    def self.partial_index_condition(create_sql : String) : String?
      bytes = create_sql.to_slice
      (0...bytes.size - 6).each do |start|
        next unless whitespace_byte?(bytes[start]) && whitespace_byte?(bytes[start + 6])
        next unless same_bytes?(bytes, start + 1, "WHERE".to_slice, true)
        return create_sql.byte_slice(start + 7).strip
      end
    end

    # The first run of ASCII digits in *text* (`text.match(/\d+/)`), or nil.
    def self.first_digits(text : String) : String?
      bytes = text.to_slice
      start = (0...bytes.size).find { |index| digit_byte?(bytes[index]) }
      return unless start
      String.new(bytes[start, digits_end(bytes, start) - start])
    end

    # The index just past the closing quote of the SQL string whose
    # opening quote is at *start*, or nil when the regex finds no string
    # there (see `blank_quoted_strings`).
    private def self.quoted_string_end(bytes : Bytes, start : Int32) : Int32?
      position = start + 1
      last_pair = nil
      while position < bytes.size
        if bytes[position] === '\''
          return position + 1 unless position + 1 < bytes.size && bytes[position + 1] === '\''
          last_pair = position
          position += 2
        else
          position += 1
        end
      end
      last_pair.try &.+(1)
    end

    private def self.same_bytes?(bytes : Bytes, start : Int32, pattern : Bytes, case_insensitive : Bool) : Bool
      pattern.each_with_index.all? do |expected, offset|
        actual = bytes[start + offset]
        actual == expected || (case_insensitive && ascii_downcase(actual) == ascii_downcase(expected))
      end
    end

    private def self.ascii_downcase(byte : UInt8) : UInt8
      byte.unsafe_chr.ascii_uppercase? ? byte + 32 : byte
    end
  end
end
