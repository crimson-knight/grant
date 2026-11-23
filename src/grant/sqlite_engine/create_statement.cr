module Grant::SQLiteEngine
  # What `sqlite_schema` stores for a CREATE TABLE or CREATE INDEX
  # statement. SQLite rewrites the start as "CREATE TABLE " or
  # "CREATE [UNIQUE] INDEX " followed by the statement's own text from the
  # unqualified object name on, dropping IF NOT EXISTS and a schema prefix
  # (sqlite3EndTable, sqlite3CreateIndex). A table without options ends at
  # its closing parenthesis; one with options (WITHOUT ROWID, STRICT), and an
  # index, run to the end of the statement, a final semicolon dropped.
  struct CreateStatement
    record Token, text : String, start : Int32, finish : Int32 do
      def keyword?(keyword : String) : Bool
        @text.compare(keyword, case_insensitive: true) == 0
      end
    end

    getter object_name : String
    # The table a CREATE INDEX names after ON.
    getter table_name : String? = nil
    getter stored_sql : String
    getter? if_not_exists : Bool

    def self.table(sql : String) : CreateStatement
      new(sql, index: false)
    end

    def self.index(sql : String) : CreateStatement
      new(sql, index: true)
    end

    private def initialize(sql : String, index : Bool)
      if sql.bytesize > Limits::MAX_SQL_BYTES
        raise LimitExceeded.new("SQL statement length", "#{sql.bytesize} bytes is more than #{Limits::MAX_SQL_BYTES}")
      end
      tokens = CreateStatement.tokenize(sql)
      position = 0
      expect = ->(keyword : String) do
        token = tokens[position]?
        raise UnsupportedSQL.new("statement that does not start CREATE #{index ? "INDEX" : "TABLE"}: #{sql[0, 60]}") unless token && token.keyword?(keyword)
        position += 1
      end
      expect.call("CREATE")
      unique = false
      if index
        if tokens[position]?.try(&.keyword?("UNIQUE"))
          unique = true
          position += 1
        end
        expect.call("INDEX")
      else
        if tokens[position]?.try { |token| token.keyword?("TEMP") || token.keyword?("TEMPORARY") }
          raise UnsupportedSQL.new("TEMP tables")
        end
        if tokens[position]?.try(&.keyword?("VIRTUAL"))
          raise UnsupportedSQL.new("virtual tables")
        end
        expect.call("TABLE")
      end
      @if_not_exists = false
      if tokens[position]?.try(&.keyword?("IF"))
        position += 1
        expect.call("NOT")
        expect.call("EXISTS")
        @if_not_exists = true
      end
      name = tokens[position]? || raise UnsupportedSQL.new("CREATE statement without a name")
      if tokens[position + 1]?.try(&.text.==("."))
        name = tokens[position + 2]? || raise UnsupportedSQL.new("CREATE statement without a name")
      end
      @object_name = CreateStatement.unquote(name.text)
      if index
        on = tokens.index { |token| token.start > name.start && token.keyword?("ON") }
        table = on ? tokens[on + 1]? : nil
        table = tokens[on + 3]? if on && tokens[on + 2]?.try(&.text.==("."))
        @table_name = table.try { |token| CreateStatement.unquote(token.text) }
      end
      finish = sql.bytesize
      if index
        last = tokens.last
        finish = last.start if last.text == ";"
      else
        closing = closing_parenthesis(tokens)
        has_options = tokens.skip_while { |token| token.start <= closing.start }.any? { |token| token.text != ";" }
        if has_options
          last = tokens.last
          finish = last.text == ";" ? last.start : sql.bytesize
        else
          finish = closing.finish
          raise UnsupportedSQL.new("CREATE TABLE ... AS SELECT") if tokens.any? { |token| token.start > closing.start && token.keyword?("AS") }
        end
      end
      kind = index ? (unique ? "CREATE UNIQUE INDEX " : "CREATE INDEX ") : "CREATE TABLE "
      @stored_sql = kind + sql.byte_slice(name.start, finish - name.start)
    end

    # The closing parenthesis of the column list.
    private def closing_parenthesis(tokens : Array(Token)) : Token
      depth = 0
      opened = false
      tokens.each do |token|
        if token.text == "("
          depth += 1
          opened = true
        elsif token.text == ")"
          depth -= 1
          return token if opened && depth == 0
        elsif !opened && token.keyword?("AS")
          raise UnsupportedSQL.new("CREATE TABLE ... AS SELECT")
        end
      end
      raise UnsupportedSQL.new("CREATE TABLE without a closed column list")
    end

    # A name as SQLite reads it: quotes removed, doubled quotes undone.
    def self.unquote(text : String) : String
      return text[1...-1] if text.starts_with?('[') && text.ends_with?(']')
      quote = text[0]?
      if quote && quote.in?('"', '\'', '`') && text.size >= 2 && text.ends_with?(quote)
        return text[1...-1].gsub("#{quote}#{quote}", quote.to_s)
      end
      text
    end

    # Splits *sql* into words, quoted names, strings, numbers and single
    # punctuation characters, with their byte offsets; comments and
    # whitespace are skipped.
    def self.tokenize(sql : String) : Array(Token)
      bytes = sql.to_slice
      tokens = [] of Token
      index = 0
      while index < bytes.size
        byte = bytes[index]
        if byte.unsafe_chr.ascii_whitespace?
          index += 1
        elsif byte == '-'.ord && bytes[index + 1]? == '-'.ord
          while index < bytes.size && bytes[index] != '\n'.ord
            index += 1
          end
        elsif byte == '/'.ord && bytes[index + 1]? == '*'.ord
          close = sql.byte_index("*/", index + 2)
          index = close ? close + 2 : bytes.size
        elsif byte.in?('"'.ord, '\''.ord, '`'.ord, '['.ord)
          closing = byte == '['.ord ? ']'.ord.to_u8 : byte
          finish = index + 1
          loop do
            break if finish >= bytes.size
            if bytes[finish] == closing
              if closing != ']'.ord && bytes[finish + 1]? == closing
                finish += 2
                next
              end
              break
            end
            finish += 1
          end
          finish = Math.min(finish + 1, bytes.size)
          tokens << Token.new(sql.byte_slice(index, finish - index), index, finish)
          index = finish
        elsif byte.unsafe_chr.ascii_alphanumeric? || byte == '_'.ord || byte >= 0x80
          finish = index
          while finish < bytes.size && (bytes[finish].unsafe_chr.ascii_alphanumeric? || bytes[finish] == '_'.ord || bytes[finish] == '$'.ord || bytes[finish] >= 0x80)
            finish += 1
          end
          tokens << Token.new(sql.byte_slice(index, finish - index), index, finish)
          index = finish
        else
          tokens << Token.new(sql.byte_slice(index, 1), index, index + 1)
          index += 1
        end
      end
      tokens
    end
  end
end
