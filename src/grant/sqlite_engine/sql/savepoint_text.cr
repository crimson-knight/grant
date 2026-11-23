module Grant::SQLiteEngine::SQL
  # Reads `SAVEPOINT name` and `RELEASE [SAVEPOINT] name` without the
  # parser, for the statements an ORM sends around every row it writes in
  # a transaction, each with a new name. It takes only the plain spelling:
  # a bare ASCII name that is not a keyword, between optional whitespace,
  # and at most one closing semicolon. Anything else returns nil and goes
  # through the parser, so the syntax tree, and every error, is the
  # parser's.
  module SavepointText
    def self.parse(sql : String) : Statement?
      bytes = sql.to_slice
      position = skip_space(bytes, 0)
      word_end = word_end(bytes, position)
      if keyword?(bytes, position, word_end, "SAVEPOINT")
        name, finish = bare_name(bytes, skip_space(bytes, word_end))
        return unless name && statement_end?(bytes, finish)
        return Savepoint.new(name)
      end
      return unless keyword?(bytes, position, word_end, "RELEASE")
      position = skip_space(bytes, word_end)
      following_end = word_end(bytes, position)
      savepoint_keyword = keyword?(bytes, position, following_end, "SAVEPOINT")
      position = skip_space(bytes, following_end) if savepoint_keyword
      name, finish = bare_name(bytes, position)
      return unless name && statement_end?(bytes, finish)
      Release.new(savepoint_keyword, name)
    end

    # The name starting at *start* when it is a bare identifier that is no
    # keyword, and the position after it.
    private def self.bare_name(bytes : Bytes, start : Int32) : {Name?, Int32}
      finish = word_end(bytes, start)
      return {nil, finish} if finish == start || digit?(bytes[start])
      return {nil, finish} if finish < bytes.size && bytes[finish] >= 0x80_u8
      return {nil, finish} if Keywords.lookup(bytes, start, finish - start)
      {Name.bare(String.new(bytes[start, finish - start])), finish}
    end

    # Only whitespace, then at most one semicolon and more whitespace.
    private def self.statement_end?(bytes : Bytes, start : Int32) : Bool
      position = skip_space(bytes, start)
      position = skip_space(bytes, position + 1) if position < bytes.size && bytes[position] == ';'.ord
      position == bytes.size
    end

    private def self.keyword?(bytes : Bytes, start : Int32, finish : Int32, keyword : String) : Bool
      return false unless finish - start == keyword.bytesize
      keyword.to_slice.each_with_index do |byte, index|
        return false unless bytes[start + index] & 0xdf_u8 == byte
      end
      true
    end

    private def self.word_end(bytes : Bytes, start : Int32) : Int32
      position = start
      while position < bytes.size && word_byte?(bytes[position])
        position += 1
      end
      position
    end

    private def self.skip_space(bytes : Bytes, start : Int32) : Int32
      position = start
      while position < bytes.size && space?(bytes[position])
        position += 1
      end
      position
    end

    private def self.word_byte?(byte : UInt8) : Bool
      (byte >= 'a'.ord && byte <= 'z'.ord) || (byte >= 'A'.ord && byte <= 'Z'.ord) || digit?(byte) || byte == '_'.ord
    end

    private def self.digit?(byte : UInt8) : Bool
      byte >= '0'.ord && byte <= '9'.ord
    end

    # The whitespace SQLite's tokenizer skips.
    private def self.space?(byte : UInt8) : Bool
      byte == ' '.ord || byte == '\t'.ord || byte == '\n'.ord || byte == '\f'.ord || byte == '\r'.ord
    end
  end
end
