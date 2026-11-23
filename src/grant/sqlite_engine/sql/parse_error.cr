module Grant::SQLiteEngine::SQL
  # Raised for SQL text that C SQLite's parser rejects. The message is the
  # one `sqlite3_prepare_v2` reports for the same text (for example
  # `near "FROM": syntax error`, `incomplete input` or
  # `unrecognized token: "'abc"`), and `offset` is the byte offset of the
  # token the parser stopped at.
  class ParseError < Error
    getter offset : Int32

    def initialize(message : String, @offset : Int32)
      super(message)
    end
  end
end
