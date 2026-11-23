module Grant::SQLiteEngine
  # The key columns of a CREATE INDEX statement (lang_createindex.html): for
  # each, the column it names (nil for an expression), the COLLATE written
  # for it (nil when none is) and whether it sorts DESC; and whether the
  # index is UNIQUE or partial (a WHERE clause).
  class IndexDefinition
    record KeyTerm, column_name : String?, collation : String?, descending : Bool = false

    getter list_of_key_terms : Array(KeyTerm)
    getter? unique : Bool
    getter? partial : Bool

    # The column each key term names, nil for an expression.
    def list_of_key_columns : Array(String?)
      @list_of_key_terms.map(&.column_name)
    end

    def self.parse(sql : String) : IndexDefinition
      tokens = SchemaTokenizer.tokenize(sql)
      open_at = tokens.index(&.punctuation?('('))
      raise SchemaTokenizer::Malformed.new("CREATE INDEX has no column list") unless open_at
      terms, after = split_key_terms(tokens, open_at + 1)
      unique = tokens.size > 1 && tokens[1].keyword?("UNIQUE")
      following = tokens[after]?
      new(terms, unique, !following.nil? && following.keyword?("WHERE"))
    end

    def initialize(@list_of_key_terms : Array(KeyTerm), @unique : Bool = false, @partial : Bool = false)
    end

    # Splits the tokens after the opening parenthesis at top-level commas,
    # up to the matching closing parenthesis. Returns the terms and the
    # position after that parenthesis.
    private def self.split_key_terms(tokens : Array(SchemaTokenizer::Token), start : Int32) : {Array(KeyTerm), Int32}
      terms = [] of KeyTerm
      current = [] of SchemaTokenizer::Token
      depth = 0
      index = start
      loop do
        token = tokens[index]? || raise SchemaTokenizer::Malformed.new("CREATE INDEX column list is not closed")
        index += 1
        if depth == 0 && (token.punctuation?(',') || token.punctuation?(')'))
          terms << key_column(current)
          current = [] of SchemaTokenizer::Token
          break if token.punctuation?(')')
          next
        end
        depth += 1 if token.punctuation?('(')
        depth -= 1 if token.punctuation?(')')
        current << token
      end
      {terms, index}
    end

    # A term is a column when, after dropping ASC/DESC and a COLLATE clause,
    # one name is left.
    private def self.key_column(term : Array(SchemaTokenizer::Token)) : KeyTerm
      words = term.dup
      last = words.last?
      descending = !last.nil? && last.keyword?("DESC")
      words.pop if last && (last.keyword?("ASC") || last.keyword?("DESC"))
      collation = nil
      if words.size >= 2 && words[-2].keyword?("COLLATE")
        collation = words[-1].text
        words.pop(2)
      end
      only = words.first?
      named = words.size == 1 && only && (only.kind.word? || only.kind.identifier?)
      KeyTerm.new(named && only ? only.text : nil, collation, descending)
    end
  end
end
