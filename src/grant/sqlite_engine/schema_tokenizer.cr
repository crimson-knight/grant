module Grant::SQLiteEngine
  # Splits the CREATE statements stored in `sqlite_schema` into tokens, enough
  # to read column definitions (lang_createtable.html) and index columns
  # (lang_createindex.html). The full SQL tokenizer arrives with the parser
  # (milestone G3).
  class SchemaTokenizer
    enum Kind
      Word       # a bare identifier or keyword
      Identifier # a quoted identifier: "x", `x` or [x]
      Text       # a string literal 'x'
      Number
      Blob # a blob literal x'00ff'
      Punctuation
    end

    record Token, kind : Kind, text : String do
      # True for a bare word equal to *keyword*, ignoring case.
      def keyword?(keyword : String) : Bool
        @kind.word? && @text.compare(keyword, case_insensitive: true) == 0
      end

      def punctuation?(char : Char) : Bool
        @kind.punctuation? && @text.size == 1 && @text[0] == char
      end

      # True for a token that names something (bare or quoted).
      def name? : Bool
        @kind.word? || @kind.identifier? || @kind.text?
      end
    end

    # Raised for text the tokenizer cannot split; callers turn it into a
    # corruption error naming the schema entry.
    class Malformed < Exception
    end

    def self.tokenize(sql : String) : Array(Token)
      new(sql).tokens
    end

    getter tokens = [] of Token

    private def initialize(sql : String)
      @reader = Char::Reader.new(sql)
      scan
    end

    private def scan : Nil
      while @reader.has_next?
        next if skip_trivia
        @tokens << next_token(@reader.current_char)
      end
    end

    # Skips whitespace and comments. Returns false at the start of a token.
    private def skip_trivia : Bool
      char = @reader.current_char
      if char.whitespace?
        @reader.next_char
      elsif char == '-' && @reader.peek_next_char == '-'
        while @reader.has_next? && @reader.current_char != '\n'
          @reader.next_char
        end
      elsif char == '/' && @reader.peek_next_char == '*'
        skip_block_comment
      else
        return false
      end
      true
    end

    private def next_token(char : Char) : Token
      if char.in?('x', 'X') && @reader.peek_next_char == '\''
        @reader.next_char
        Token.new(Kind::Blob, quoted('\''))
      elsif char.letter? || char == '_' || char.ord >= 0x80
        Token.new(Kind::Word, word)
      elsif char.ascii_number? || (char == '.' && @reader.peek_next_char.ascii_number?)
        Token.new(Kind::Number, number)
      else
        quoted_token(char) || punctuation(char)
      end
    end

    private def quoted_token(char : Char) : Token?
      case char
      when '\''     then Token.new(Kind::Text, quoted('\''))
      when '"', '`' then Token.new(Kind::Identifier, quoted(char))
      when '['      then Token.new(Kind::Identifier, bracketed)
      end
    end

    private def punctuation(char : Char) : Token
      @reader.next_char
      Token.new(Kind::Punctuation, char.to_s)
    end

    private def skip_block_comment : Nil
      @reader.next_char
      @reader.next_char
      while @reader.has_next?
        if @reader.current_char == '*' && @reader.peek_next_char == '/'
          @reader.next_char
          @reader.next_char
          return
        end
        @reader.next_char
      end
    end

    private def word : String
      String.build do |io|
        while @reader.has_next?
          char = @reader.current_char
          break unless char.letter? || char.ascii_number? || char == '_' || char == '$' || char.ord >= 0x80
          io << char
          @reader.next_char
        end
      end
    end

    private def number : String
      String.build do |io|
        while @reader.has_next?
          char = @reader.current_char
          if char.ascii_alphanumeric? || char == '.' || char == '_'
            io << char
            @reader.next_char
            if char.in?('e', 'E') && @reader.has_next? && @reader.current_char.in?('+', '-')
              io << @reader.current_char
              @reader.next_char
            end
          else
            break
          end
        end
      end
    end

    # Reads a quoted run in which a doubled quote stands for one quote.
    private def quoted(quote : Char) : String
      @reader.next_char
      String.build do |io|
        loop do
          raise Malformed.new("unterminated #{quote} quote") unless @reader.has_next?
          char = @reader.current_char
          @reader.next_char
          if char == quote
            break unless @reader.has_next? && @reader.current_char == quote
            @reader.next_char
          end
          io << char
        end
      end
    end

    private def bracketed : String
      @reader.next_char
      String.build do |io|
        loop do
          raise Malformed.new("unterminated [ quote") unless @reader.has_next?
          char = @reader.current_char
          @reader.next_char
          break if char == ']'
          io << char
        end
      end
    end
  end
end
