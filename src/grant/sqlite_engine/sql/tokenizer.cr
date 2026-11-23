module Grant::SQLiteEngine::SQL
  # Splits SQL text into tokens the way SQLite's tokenizer does
  # (tokenize.c, sqlite3GetToken and sqlite3RunParser): whitespace and
  # comments are skipped, keywords are recognized without regard to case,
  # WINDOW, OVER and FILTER become keywords only where SQLite treats them as
  # keywords, and a NUL byte ends the input as it ends a C string.
  #
  # Tokens are produced on demand, so text after the first statement is
  # never examined, as in `sqlite3_prepare_v2`.
  class Tokenizer
    getter source : String
    @bytes : Bytes
    @position = 0
    @previous_kind = TokenKind::EndOfInput

    def initialize(@source : String)
      bytes = @source.to_slice
      if nul = bytes.index(0_u8)
        bytes = bytes[0, nul]
      end
      @bytes = bytes
    end

    # The byte length of the input, up to any NUL byte.
    def size : Int32
      @bytes.size
    end

    # Returns the next token, or an `EndOfInput` token at the end.
    def next_token : Token
      loop do
        start = @position
        if start >= @bytes.size
          return Token.new(TokenKind::EndOfInput, start, 0)
        end
        kind, length, trivia = scan(start)
        @position = start + length
        next if trivia
        kind = analyze_window_keyword(kind, @position)
        @previous_kind = kind
        return Token.new(kind, start, length)
      end
    end

    # The token's text exactly as written.
    def text(token : Token) : String
      String.new(@bytes[token.start, token.size])
    end

    def byte_at(offset : Int32) : UInt8
      @bytes[offset]
    end

    # tokenize.c's analyzeWindowKeyword, analyzeOverKeyword and
    # analyzeFilterKeyword.
    private def analyze_window_keyword(kind : TokenKind, after : Int32) : TokenKind
      case kind
      when TokenKind::Window
        first, position = peek_class(after)
        return TokenKind::Identifier unless first.identifier?
        second, _ = peek_class(position)
        second == TokenKind::As ? TokenKind::Window : TokenKind::Identifier
      when TokenKind::Over
        return TokenKind::Identifier unless @previous_kind.right_paren?
        following, _ = peek_class(after)
        following.left_paren? || following.identifier? ? TokenKind::Over : TokenKind::Identifier
      when TokenKind::Filter
        return TokenKind::Identifier unless @previous_kind.right_paren?
        following, _ = peek_class(after)
        following.left_paren? ? TokenKind::Filter : TokenKind::Identifier
      else
        kind
      end
    end

    # tokenize.c's getToken: the next non-trivia token, with every token
    # that can stand as a name reported as `Identifier`.
    private def peek_class(position : Int32) : {TokenKind, Int32}
      loop do
        return {TokenKind::EndOfInput, position} if position >= @bytes.size
        kind, length, trivia = scan(position)
        position += length
        next if trivia
        if kind.identifier? || kind.string? || kind.join_keyword? || kind.window? ||
           kind.over? || Keywords.falls_back_to_identifier?(kind)
          kind = TokenKind::Identifier
        end
        return {kind, position}
      end
    end

    # sqlite3GetToken: the kind and byte length of the token at *start*,
    # and whether it is whitespace or a comment.
    private def scan(start : Int32) : {TokenKind, Int32, Bool}
      bytes = @bytes
      byte = bytes[start]
      case byte
      when ' '.ord, '\t'.ord, '\n'.ord, '\f'.ord, '\r'.ord, 0x0b
        position = start + 1
        while position < bytes.size && space?(bytes[position])
          position += 1
        end
        {TokenKind::EndOfInput, position - start, true}
      when '-'.ord
        following = at(start + 1)
        if following == '-'.ord
          position = start + 2
          while position < bytes.size && bytes[position] != '\n'.ord
            position += 1
          end
          {TokenKind::EndOfInput, position - start, true}
        elsif following == '>'.ord
          {TokenKind::Pointer, at(start + 2) == '>'.ord ? 3 : 2, false}
        else
          {TokenKind::Minus, 1, false}
        end
      when '('.ord then {TokenKind::LeftParen, 1, false}
      when ')'.ord then {TokenKind::RightParen, 1, false}
      when ';'.ord then {TokenKind::Semicolon, 1, false}
      when '+'.ord then {TokenKind::Plus, 1, false}
      when '*'.ord then {TokenKind::Star, 1, false}
      when '/'.ord
        if at(start + 1) == '*'.ord && start + 2 < bytes.size
          position = start + 3
          previous = bytes[start + 2]
          while position < bytes.size && !(previous == '*'.ord && bytes[position] == '/'.ord)
            previous = bytes[position]
            position += 1
          end
          position += 1 if position < bytes.size
          {TokenKind::EndOfInput, position - start, true}
        else
          {TokenKind::Slash, 1, false}
        end
      when '%'.ord then {TokenKind::Remainder, 1, false}
      when '='.ord then {TokenKind::Equal, at(start + 1) == '='.ord ? 2 : 1, false}
      when '<'.ord
        case at(start + 1)
        when '='.ord then {TokenKind::LessOrEqual, 2, false}
        when '>'.ord then {TokenKind::NotEqual, 2, false}
        when '<'.ord then {TokenKind::ShiftLeft, 2, false}
        else              {TokenKind::Less, 1, false}
        end
      when '>'.ord
        case at(start + 1)
        when '='.ord then {TokenKind::GreaterOrEqual, 2, false}
        when '>'.ord then {TokenKind::ShiftRight, 2, false}
        else              {TokenKind::Greater, 1, false}
        end
      when '!'.ord
        at(start + 1) == '='.ord ? {TokenKind::NotEqual, 2, false} : {TokenKind::Illegal, 1, false}
      when '|'.ord
        at(start + 1) == '|'.ord ? {TokenKind::Concat, 2, false} : {TokenKind::BitOr, 1, false}
      when ','.ord then {TokenKind::Comma, 1, false}
      when '&'.ord then {TokenKind::BitAnd, 1, false}
      when '~'.ord then {TokenKind::BitNot, 1, false}
      when '\''.ord, '"'.ord, '`'.ord
        scan_quoted(start, byte)
      when '.'.ord
        digit?(at(start + 1)) ? scan_number(start) : {TokenKind::Dot, 1, false}
      when '0'.ord..'9'.ord
        scan_number(start)
      when '['.ord
        position = start + 1
        while position < bytes.size && bytes[position] != ']'.ord
          position += 1
        end
        if position < bytes.size
          {TokenKind::Identifier, position + 1 - start, false}
        else
          {TokenKind::Illegal, position - start, false}
        end
      when '?'.ord
        position = start + 1
        while position < bytes.size && digit?(bytes[position])
          position += 1
        end
        {TokenKind::Variable, position - start, false}
      when '$'.ord, '@'.ord, ':'.ord, '#'.ord
        scan_named_variable(start)
      when 'x'.ord, 'X'.ord
        at(start + 1) == '\''.ord ? scan_blob(start) : scan_word(start)
      when 0xef
        if at(start + 1) == 0xbb && at(start + 2) == 0xbf
          {TokenKind::EndOfInput, 3, true}
        else
          scan_word(start)
        end
      else
        if letter?(byte) || byte == '_'.ord || byte >= 0x80
          scan_word(start)
        else
          {TokenKind::Illegal, 1, false}
        end
      end
    end

    private def scan_word(start : Int32) : {TokenKind, Int32, Bool}
      position = start + 1
      while position < @bytes.size && identifier_byte?(@bytes[position])
        position += 1
      end
      length = position - start
      {keyword_kind(start, length), length, false}
    end

    private def keyword_kind(start : Int32, length : Int32) : TokenKind
      return TokenKind::Identifier if length < 2 || length > Keywords::MAX_KEYWORD_SIZE
      word = String.build(length) do |io|
        length.times do |index|
          byte = @bytes[start + index]
          return TokenKind::Identifier if byte >= 0x80
          io.write_byte(byte >= 'a'.ord && byte <= 'z'.ord ? byte - 32 : byte)
        end
      end
      Keywords::TABLE[word]? || TokenKind::Identifier
    end

    private def scan_quoted(start : Int32, quote : UInt8) : {TokenKind, Int32, Bool}
      position = start + 1
      while position < @bytes.size
        if @bytes[position] == quote
          if at(position + 1) == quote
            position += 2
            next
          end
          kind = quote == '\''.ord ? TokenKind::String : TokenKind::Identifier
          return {kind, position + 1 - start, false}
        end
        position += 1
      end
      {TokenKind::Illegal, position - start, false}
    end

    private def scan_number(start : Int32) : {TokenKind, Int32, Bool}
      bytes = @bytes
      kind = TokenKind::Integer
      position = start
      if bytes[start] == '0'.ord && (at(start + 1) == 'x'.ord || at(start + 1) == 'X'.ord) && hex_digit?(at(start + 2))
        position = start + 3
        loop do
          byte = at(position)
          if hex_digit?(byte)
          elsif byte == '_'.ord
            kind = TokenKind::QuotedNumber
          else
            break
          end
          position += 1
        end
      else
        kind, position = scan_digits(position, kind)
        if at(position) == '.'.ord
          kind = TokenKind::Float if kind.integer?
          kind, position = scan_digits(position + 1, kind)
        end
        exponent = at(position)
        if (exponent == 'e'.ord || exponent == 'E'.ord) &&
           (digit?(at(position + 1)) || ((at(position + 1) == '+'.ord || at(position + 1) == '-'.ord) && digit?(at(position + 2))))
          kind = TokenKind::Float if kind.integer?
          kind, position = scan_digits(position + 2, kind)
        end
      end
      while position < bytes.size && identifier_byte?(bytes[position])
        kind = TokenKind::Illegal
        position += 1
      end
      {kind, position - start, false}
    end

    private def scan_digits(position : Int32, kind : TokenKind) : {TokenKind, Int32}
      loop do
        byte = at(position)
        if digit?(byte)
        elsif byte == '_'.ord
          kind = TokenKind::QuotedNumber
        else
          return {kind, position}
        end
        position += 1
      end
    end

    # `$name`, `@name`, `:name` and `#name`, with the Tcl forms `::` inside
    # a name and a `(...)` suffix.
    private def scan_named_variable(start : Int32) : {TokenKind, Int32, Bool}
      bytes = @bytes
      count = 0
      position = start + 1
      kind = TokenKind::Variable
      while position < bytes.size
        byte = bytes[position]
        if identifier_byte?(byte)
          count += 1
        elsif byte == '('.ord && count > 0
          position += 1
          while position < bytes.size && !space?(bytes[position]) && bytes[position] != ')'.ord
            position += 1
          end
          if position < bytes.size && bytes[position] == ')'.ord
            position += 1
          else
            kind = TokenKind::Illegal
          end
          break
        elsif byte == ':'.ord && at(position + 1) == ':'.ord
          position += 1
        else
          break
        end
        position += 1
      end
      kind = TokenKind::Illegal if count == 0
      {kind, position - start, false}
    end

    private def scan_blob(start : Int32) : {TokenKind, Int32, Bool}
      position = start + 2
      while position < @bytes.size && hex_digit?(@bytes[position])
        position += 1
      end
      kind = TokenKind::Blob
      if at(position) != '\''.ord || (position - start).odd?
        kind = TokenKind::Illegal
        while position < @bytes.size && @bytes[position] != '\''.ord
          position += 1
        end
      end
      position += 1 if position < @bytes.size
      {kind, position - start, false}
    end

    # The byte at *offset*, or 0 past the end (C's terminating NUL).
    private def at(offset : Int32) : UInt8
      offset < @bytes.size ? @bytes[offset] : 0_u8
    end

    private def space?(byte : UInt8) : Bool
      byte == ' '.ord || (byte >= 0x09 && byte <= 0x0d)
    end

    private def digit?(byte : UInt8) : Bool
      byte >= '0'.ord && byte <= '9'.ord
    end

    private def hex_digit?(byte : UInt8) : Bool
      digit?(byte) || (byte >= 'a'.ord && byte <= 'f'.ord) || (byte >= 'A'.ord && byte <= 'F'.ord)
    end

    private def letter?(byte : UInt8) : Bool
      (byte >= 'a'.ord && byte <= 'z'.ord) || (byte >= 'A'.ord && byte <= 'Z'.ord)
    end

    # sqlite3IsIdChar: letters, digits, `_`, `$` and every byte of a
    # multi-byte UTF-8 character.
    private def identifier_byte?(byte : UInt8) : Bool
      letter?(byte) || digit?(byte) || byte == '_'.ord || byte == '$'.ord || byte >= 0x80
    end
  end
end
