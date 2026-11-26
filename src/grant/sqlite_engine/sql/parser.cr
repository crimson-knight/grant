module Grant::SQLiteEngine::SQL
  # A recursive-descent parser for SQLite's statement grammar (parse.y),
  # producing the syntax tree in `ast.cr`.
  #
  # It accepts exactly the text C SQLite's parser accepts: keywords stand as
  # names where parse.y lets them fall back to identifiers, and the checks
  # SQLite makes inside its grammar actions while parsing (a second PRIMARY
  # KEY, AUTOINCREMENT off an INTEGER PRIMARY KEY, a non-constant DEFAULT,
  # an unknown join type, ORDER BY before UNION, parameter numbers, the
  # expression depth limit, and the rest) raise the same messages. Name
  # resolution against a schema is not a parser concern.
  #
  # ```
  # statement = Grant::SQLiteEngine::SQL::Parser.parse("SELECT id FROM users WHERE email = ?")
  # statement.as(Grant::SQLiteEngine::SQL::SelectStatement).cores.size # => 1
  # ```
  class Parser
    include ExpressionParsing
    include SelectParsing
    include TableParsing
    include StatementParsing

    # Parses the first statement of *sql*, as `sqlite3_prepare_v2` does:
    # leading semicolons are skipped, text after the statement's semicolon
    # is not examined, and nil is returned when there is no statement.
    def self.parse(sql : String) : Statement?
      new(sql).parse_first
    end

    # Parses a CREATE statement read from sqlite_schema, where SQLite's own
    # names (sqlite_sequence, sqlite_stat1) are allowed (sqlite3CheckObjectName
    # skips the check while the schema loads).
    def self.parse_schema(sql : String) : Statement?
      parser = new(sql)
      parser.reading_schema = true
      parser.parse_first
    end

    # Parses every statement of *sql*.
    def self.parse_all(sql : String) : Array(Statement)
      new(sql).parse_every
    end

    @tokenizer : Tokenizer
    @lookahead = Array(Token).new(4)
    @depth = 0
    @parameter_count = 0
    # The number of each named parameter of the statement being parsed;
    # nil until it names one.
    @named_parameters : Hash(String, Int32)? = nil
    # The parameter names of a statement that names none, shared by every
    # such statement: nothing changes it.
    NO_PARAMETER_NAMES = {} of String => Int32
    # Set once a WITH clause names a table (parse.y withnm, pParse->bHasWith).
    @has_with = false
    # Inside a trigger body, which SQLite parses but does not resolve.
    @in_trigger = false
    protected property? reading_schema = false

    protected def initialize(sql : String)
      if sql.bytesize > Limits::MAX_SQL_LENGTH
        raise ParseError.new("string or blob too big", 0)
      end
      @tokenizer = Tokenizer.new(sql)
    end

    protected def parse_first : Statement?
      skip_semicolons
      return if kind.end_of_input?
      statement = parse_statement
      expect_statement_end
      statement
    end

    protected def parse_every : Array(Statement)
      statements = [] of Statement
      loop do
        skip_semicolons
        break if kind.end_of_input?
        @parameter_count = 0
        @named_parameters = nil
        @has_with = false
        statements << parse_statement
        expect_statement_end
      end
      statements
    end

    private def skip_semicolons : Nil
      while kind.semicolon?
        advance
      end
    end

    private def expect_statement_end : Nil
      return if kind.end_of_input?
      expect(TokenKind::Semicolon)
    end

    # ------------------------------------------------------------ tokens

    private def peek(offset : Int32 = 0) : Token
      while @lookahead.size <= offset
        token = @tokenizer.next_token
        if token.kind.illegal?
          raise ParseError.new(%(unrecognized token: "#{@tokenizer.text(token)}"), token.start)
        end
        @lookahead << token
      end
      @lookahead[offset]
    end

    private def kind(offset : Int32 = 0) : TokenKind
      peek(offset).kind
    end

    private def advance : Token
      token = peek
      @lookahead.shift
      token
    end

    private def accept(expected : TokenKind) : Bool
      return false unless kind == expected
      advance
      true
    end

    private def expect(expected : TokenKind) : Token
      syntax_error unless kind == expected
      advance
    end

    # The texts of the last tokens `text` returned, so a word the statement
    # repeats (the table in `users.id`, `users.email` and `FROM users`)
    # shares one String; Strings never change, so sharing is safe.
    RECENT_TEXT_CAPACITY = 8
    @list_of_recent_texts = StaticArray(String, RECENT_TEXT_CAPACITY).new("")
    @recent_text_count = 0

    private def text(token : Token) : String
      known_count = Math.min(@recent_text_count, RECENT_TEXT_CAPACITY)
      known_count.times do |index|
        known = @list_of_recent_texts.unsafe_fetch(index)
        return known if @tokenizer.text_is?(token, known)
      end
      fresh = @tokenizer.text(token)
      @list_of_recent_texts[@recent_text_count % RECENT_TEXT_CAPACITY] = fresh
      @recent_text_count &+= 1
      fresh
    end

    # parse.y's %syntax_error: `near "X": syntax error`, or `incomplete
    # input` at the end of the text.
    private def syntax_error(token : Token = peek) : NoReturn
      if token.kind.end_of_input?
        raise ParseError.new("incomplete input", token.start)
      end
      raise ParseError.new(%(near "#{text(token)}": syntax error), token.start)
    end

    # An error SQLite raises from a grammar action, at the current token.
    private def action_error(message : String) : NoReturn
      raise ParseError.new(message, peek.start)
    end

    # Guards recursion so deeply nested input cannot exhaust the stack.
    private def nested(&)
      @depth += 1
      if @depth > Limits::MAX_PARSER_NESTING
        action_error("Expression tree is too large (maximum depth #{Limits::MAX_EXPRESSION_DEPTH})")
      end
      begin
        yield
      ensure
        @depth -= 1
      end
    end

    # ------------------------------------------------------------- names

    # A keyword that parse.y lets stand as an identifier, or an identifier.
    private def identifier_kind?(token_kind : TokenKind) : Bool
      token_kind.identifier? || Keywords.falls_back_to_identifier?(token_kind)
    end

    # parse.y's `nm`: ID, STRING, INDEXED or a JOIN keyword.
    private def nm?(token_kind : TokenKind = kind) : Bool
      identifier_kind?(token_kind) || token_kind.string? || token_kind.indexed? || token_kind.join_keyword?
    end

    # parse.y's `ids`: ID or STRING.
    private def ids?(token_kind : TokenKind = kind) : Bool
      identifier_kind?(token_kind) || token_kind.string?
    end

    # parse.y's `idj`: ID, INDEXED or a JOIN keyword.
    private def idj?(token_kind : TokenKind = kind) : Bool
      identifier_kind?(token_kind) || token_kind.indexed? || token_kind.join_keyword?
    end

    private def parse_nm : Name
      syntax_error unless nm?
      name_of(advance)
    end

    private def parse_ids : Name
      syntax_error unless ids?
      name_of(advance)
    end

    private def name_of(token : Token) : Name
      raw = text(token)
      Name.new(Parser.dequote(raw), raw)
    end

    # sqlite3Dequote: removes the quotes around "x", `x`, [x] or 'x' and
    # undoubles quotes inside.
    def self.dequote(raw : String) : String
      return raw if raw.empty?
      quote = raw[0]
      case quote
      when '[' then raw[1, raw.size - 2]
      when '"', '`', '\''
        raw[1, raw.size - 2].gsub("#{quote}#{quote}", quote.to_s)
      else
        raw
      end
    end

    # `nm [. nm]`: returns {schema, name}.
    private def parse_qualified_name : {Name?, Name}
      first = parse_nm
      if accept(TokenKind::Dot)
        {first, parse_nm}
      else
        {nil, first}
      end
    end

    # `( nm, ... )` (parse.y idlist).
    private def parse_name_list : Array(Name)
      expect(TokenKind::LeftParen)
      names = [parse_nm]
      while accept(TokenKind::Comma)
        names << parse_nm
      end
      expect(TokenKind::RightParen)
      names
    end

    # parse.y's eidlist: names that may carry COLLATE and ASC/DESC, which
    # are a syntax error outside a schema reparse.
    private def parse_eidlist : Array(Name)
      expect(TokenKind::LeftParen)
      names = [] of Name
      loop do
        name_token = peek
        name = parse_nm
        has_collate = false
        if accept(TokenKind::Collate)
          parse_ids
          has_collate = true
        end
        has_order = accept(TokenKind::Asc) || accept(TokenKind::Desc)
        if has_collate || has_order
          action_error(%(syntax error after column name "#{text(name_token)}"))
        end
        names << name
        break unless accept(TokenKind::Comma)
      end
      expect(TokenKind::RightParen)
      names
    end

    private def parse_conflict_resolution : ConflictResolution
      case kind
      when .rollback? then advance; ConflictResolution::Rollback
      when .abort?    then advance; ConflictResolution::Abort
      when .fail?     then advance; ConflictResolution::Fail
      when .ignore?   then advance; ConflictResolution::Ignore
      when .replace?  then advance; ConflictResolution::Replace
      else                 syntax_error
      end
    end

    # `[ON CONFLICT resolution]` (parse.y onconf).
    private def parse_on_conflict : ConflictResolution?
      return unless kind.on?
      advance
      expect(TokenKind::Conflict)
      parse_conflict_resolution
    end

    # `[OR resolution]` (parse.y orconf).
    private def parse_or_conflict : ConflictResolution?
      return unless accept(TokenKind::Or)
      parse_conflict_resolution
    end
  end
end
