module Grant::SQLiteEngine::Query
  # LIKE and GLOB matching, ported from func.c `patternCompare`: LIKE folds
  # ASCII case only and takes an optional escape character; GLOB is case
  # sensitive and understands `[...]` sets. Text ends at its first zero
  # byte, as it does in C.
  module PatternMatch
    MATCH             = 0
    NO_MATCH          = 1
    NO_WILDCARD_MATCH = 2

    # The rules of one matcher.
    record Rules, match_all : UInt32, match_one : UInt32, match_set : UInt32, no_case : Bool

    LIKE_RULES = Rules.new('%'.ord.to_u32, '_'.ord.to_u32, 0_u32, true)
    GLOB_RULES = Rules.new('*'.ord.to_u32, '?'.ord.to_u32, '['.ord.to_u32, false)

    # A pointer into a zero-terminated copy of some text.
    private struct Cursor
      getter bytes : Bytes
      property position : Int32

      def initialize(@bytes : Bytes, @position : Int32 = 0)
      end

      @[AlwaysInline]
      def peek : UInt8
        @bytes.unsafe_fetch(@position)
      end

      # sqlite3Utf8Read.
      def read : UInt32
        byte = @bytes.unsafe_fetch(@position)
        @position += 1
        return byte.to_u32 if byte < 0xc0
        code = PatternMatch.lead_bits(byte)
        while @bytes.unsafe_fetch(@position) & 0xc0 == 0x80
          code = (code << 6) + (0x3f_u32 & @bytes.unsafe_fetch(@position))
          @position += 1
        end
        if code < 0x80 || code & 0xFFFFF800_u32 == 0xD800 || code & 0xFFFFFFFE_u32 == 0xFFFE
          code = 0xFFFD_u32
        end
        code
      end

      def skip_character : Nil
        byte = @bytes.unsafe_fetch(@position)
        @position += 1
        return if byte < 0xc0
        while @bytes.unsafe_fetch(@position) & 0xc0 == 0x80
          @position += 1
        end
      end
    end

    # sqlite3Utf8Trans1.
    def self.lead_bits(byte : UInt8) : UInt32
      if byte < 0xe0
        (byte & 0x1f).to_u32
      elsif byte < 0xf0
        (byte & 0x0f).to_u32
      elsif byte < 0xf8
        (byte & 0x07).to_u32
      elsif byte < 0xfc
        (byte & 0x03).to_u32
      elsif byte < 0xfe
        (byte & 0x01).to_u32
      else
        0_u32
      end
    end

    def self.terminated(text : String) : Bytes
      bytes = Bytes.new(text.bytesize + 1)
      bytes.copy_from(text.to_unsafe, text.bytesize)
      bytes
    end

    # True when *text* matches *pattern* under *rules*; *escape* is the
    # LIKE escape character or `[` for GLOB (0 for none).
    def self.match?(pattern : String, text : String, rules : Rules, escape : UInt32) : Bool
      compare(Cursor.new(terminated(pattern)), Cursor.new(terminated(text)), rules, escape) == MATCH
    end

    @[AlwaysInline]
    private def self.lower(code : UInt32) : UInt32
      code >= 0x41 && code <= 0x5a ? code + 32 : code
    end

    @[AlwaysInline]
    private def self.upper(code : UInt32) : UInt32
      code >= 0x61 && code <= 0x7a ? code - 32 : code
    end

    private def self.compare(pattern : Cursor, string : Cursor, rules : Rules, match_other : UInt32) : Int32
      match_one = rules.match_one
      match_all = rules.match_all
      escaped_end = -1
      loop do
        code = pattern.read
        break if code == 0
        if code == match_all
          loop do
            code = pattern.read
            break unless code == match_all || (code == match_one && match_one != 0)
            return NO_WILDCARD_MATCH if code == match_one && string.read == 0
          end
          return MATCH if code == 0
          if code == match_other
            if rules.match_set == 0
              code = pattern.read
              return NO_WILDCARD_MATCH if code == 0
            else
              set_start = Cursor.new(pattern.bytes, pattern.position - 1)
              while string.peek != 0
                result = compare(set_start, Cursor.new(string.bytes, string.position), rules, match_other)
                return result if result != NO_MATCH
                string.skip_character
              end
              return NO_WILDCARD_MATCH
            end
          end
          if code < 0x80
            stop_upper = rules.no_case ? upper(code) : code
            stop_lower = rules.no_case ? lower(code) : code
            loop do
              while (byte = string.peek) != 0 && byte != stop_upper && byte != stop_lower
                string.position += 1
              end
              break if string.peek == 0
              string.position += 1
              result = compare(Cursor.new(pattern.bytes, pattern.position), Cursor.new(string.bytes, string.position), rules, match_other)
              return result if result != NO_MATCH
            end
          else
            while (other = string.read) != 0
              next unless other == code
              result = compare(Cursor.new(pattern.bytes, pattern.position), Cursor.new(string.bytes, string.position), rules, match_other)
              return result if result != NO_MATCH
            end
          end
          return NO_WILDCARD_MATCH
        end
        if code == match_other
          if rules.match_set == 0
            code = pattern.read
            return NO_MATCH if code == 0
            escaped_end = pattern.position
          else
            prior = 0_u32
            seen = false
            invert = false
            code = string.read
            return NO_MATCH if code == 0
            member = pattern.read
            if member == '^'.ord
              invert = true
              member = pattern.read
            end
            if member == ']'.ord
              seen = true if code == ']'.ord
              member = pattern.read
            end
            while member != 0 && member != ']'.ord
              if member == '-'.ord && pattern.peek != ']'.ord && pattern.peek != 0 && prior > 0
                member = pattern.read
                seen = true if code >= prior && code <= member
                prior = 0_u32
              else
                seen = true if code == member
                prior = member
              end
              member = pattern.read
            end
            return NO_MATCH if member == 0 || seen == invert
            next
          end
        end
        other = string.read
        next if code == other
        next if rules.no_case && lower(code) == lower(other) && code < 0x80 && other < 0x80
        next if code == match_one && pattern.position != escaped_end && other != 0
        return NO_MATCH
      end
      string.peek == 0 ? MATCH : NO_MATCH
    end
  end
end
