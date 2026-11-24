module Grant::SQLiteEngine
  # A column of a table, as its CREATE TABLE statement declares it.
  class ColumnDefinition
    # How a generated column is kept (lang_createtable.html, "Generated
    # Columns"). Ordinary columns are `None`.
    enum Generated
      None
      Stored
      Virtual
    end

    getter column_name : String
    getter declared_type : String
    # A STRICT table's ANY column has BLOB affinity: it keeps every value
    # as given (sqlite3EndTable sets SQLITE_AFF_BLOB for COLTYPE_ANY).
    property affinity : Affinity
    property? primary_key = false
    property? primary_key_descending = false
    property? not_null = false
    property generated = Generated::None
    # The DEFAULT clause: a literal value, or the clause's text when it is an
    # expression the reader does not evaluate (needed only for rows written
    # before an ALTER TABLE ADD COLUMN).
    property default_value : Value = nil
    property default_expression : String? = nil
    # The text of a real literal DEFAULT, with its minus sign (a plus sign is
    # dropped). SQLite builds such a default from the literal's text
    # (sqlite3ValueFromExpr), so a TEXT column reads it back as written.
    property default_real_literal : String? = nil
    # `DEFAULT -'text'`: the default is the negated text (parse.y keeps
    # TK_UMINUS over a string), so it reads as the text's numeric value
    # negated.
    property? default_negated_text = false
    # The column's COLLATE clause; BINARY when it has none.
    property collation = "BINARY"

    def initialize(@column_name : String, @declared_type : String)
      @affinity = Affinity.from_declared_type(@declared_type)
    end
  end

  # What the reader needs from a CREATE TABLE statement: the columns in
  # order, their affinities and defaults, the primary key, whether the table
  # is WITHOUT ROWID, and which column aliases the rowid.
  #
  # Reads the forms of lang_createtable.html. Text it cannot read raises
  # `SchemaTokenizer::Malformed`, which `Schema` reports as corruption.
  class TableDefinition
    getter table_name : String
    getter list_of_columns = [] of ColumnDefinition
    # Primary key column names in key order.
    getter list_of_primary_key_columns = [] of String
    # The COLLATE written in the PRIMARY KEY clause for each key column, or
    # nil where the column's own collation applies.
    getter list_of_primary_key_collations = [] of String?
    # Column lists of the PRIMARY KEY and UNIQUE constraints in the order
    # SQLite creates their automatic indexes.
    getter list_of_unique_constraints = [] of Array(String)
    # The key terms of each entry of `list_of_unique_constraints`, with the
    # COLLATE and DESC written for each column.
    getter list_of_unique_constraint_terms = [] of Array(IndexDefinition::KeyTerm)
    @list_of_written_constraints = [] of {Array(String), Array(IndexDefinition::KeyTerm), Bool}
    # True when the INTEGER PRIMARY KEY is declared AUTOINCREMENT.
    getter? autoincrement = false
    getter? without_rowid = false
    getter? strict = false
    # Index into `list_of_columns` of the INTEGER PRIMARY KEY column that
    # aliases the rowid, or nil.
    getter rowid_alias_index : Int32? = nil

    COLUMN_CONSTRAINT_KEYWORDS = %w[CONSTRAINT PRIMARY NOT NULL UNIQUE CHECK DEFAULT COLLATE REFERENCES GENERATED AS]
    TABLE_CONSTRAINT_KEYWORDS  = %w[CONSTRAINT PRIMARY UNIQUE CHECK FOREIGN]

    def self.parse(sql : String) : TableDefinition
      new(SchemaTokenizer.tokenize(sql))
    end

    @position = 0

    private def initialize(@tokens : Array(SchemaTokenizer::Token))
      expect_keyword("CREATE")
      skip_keyword("TEMP") || skip_keyword("TEMPORARY")
      expect_keyword("TABLE")
      if skip_keyword("IF")
        expect_keyword("NOT")
        expect_keyword("EXISTS")
      end
      @table_name = qualified_name
      expect_punctuation('(')
      loop do
        if table_constraint_start?
          table_constraints
          break
        end
        column_definition
        break unless skip_punctuation(',')
      end
      expect_punctuation(')')
      table_options
      resolve_rowid_alias
    end

    # Position in the record of each column: the table's declared order for
    # rowid tables; for WITHOUT ROWID tables the primary key columns come
    # first (fileformat2.html §2.5). Virtual generated columns are not stored.
    def stored_column_order : Array(Int32)
      stored = (0...@list_of_columns.size).reject { |index| @list_of_columns[index].generated.virtual? }
      return stored unless @without_rowid
      key_indexes = primary_key_positions.compact_map { |position| column_index(@list_of_primary_key_columns[position]) }
      key_indexes + stored.reject { |index| key_indexes.includes?(index) }
    end

    # The positions in `list_of_primary_key_columns` that the key keeps: a
    # WITHOUT ROWID table drops a column repeated with the same collation
    # (convertToWithoutRowidTable, "PRIMARY KEY(a,b,a)" is "PRIMARY
    # KEY(a,b)").
    def primary_key_positions : Array(Int32)
      positions = (0...@list_of_primary_key_columns.size).to_a
      return positions unless @without_rowid
      kept = [] of Int32
      positions.each do |position|
        name = @list_of_primary_key_columns[position]
        collation = primary_key_collation(position)
        repeated = kept.any? do |earlier|
          @list_of_primary_key_columns[earlier].compare(name, case_insensitive: true) == 0 &&
            primary_key_collation(earlier).compare(collation, case_insensitive: true) == 0
        end
        kept << position unless repeated
      end
      kept
    end

    # Index of the column named *column_name* (case-insensitive), or nil.
    def column_index(column_name : String) : Int32?
      @list_of_columns.index { |column| column.column_name.compare(column_name, case_insensitive: true) == 0 }
    end

    private def column_definition : Nil
      column = ColumnDefinition.new(name_token, type_name)
      @list_of_columns << column
      until at_end? || current.punctuation?(',') || current.punctuation?(')')
        column_constraint(column)
      end
    end

    private def type_name : String
      words = [] of String
      while !at_end? && current.name? && !column_constraint_start?
        words << advance.text
      end
      if !words.empty? && skip_punctuation('(')
        size = String.build do |io|
          until at_end? || current.punctuation?(')')
            io << advance.text
          end
        end
        expect_punctuation(')')
        words[-1] = "#{words[-1]}(#{size})"
      end
      words.join(' ')
    end

    private def column_constraint(column : ColumnDefinition) : Nil
      return if key_or_null_constraint(column)
      if skip_keyword("CONSTRAINT")
        name_token
      elsif skip_keyword("CHECK")
        skip_parenthesized
      elsif skip_keyword("DEFAULT")
        default_clause(column)
      elsif skip_keyword("COLLATE")
        column.collation = name_token
      elsif skip_keyword("REFERENCES")
        foreign_key_clause
      elsif skip_keyword("GENERATED")
        expect_keyword("ALWAYS")
        generated_clause(column)
      elsif current.keyword?("AS")
        generated_clause(column)
      else
        malformed("unexpected #{current.text} in column #{column.column_name}")
      end
    end

    # PRIMARY KEY, NOT NULL, NULL and UNIQUE. Returns false when the next
    # constraint is another kind.
    private def key_or_null_constraint(column : ColumnDefinition) : Bool
      if skip_keyword("PRIMARY")
        expect_keyword("KEY")
        column.primary_key = true
        column.primary_key_descending = true if skip_keyword("DESC")
        skip_keyword("ASC")
        conflict_clause
        @autoincrement = true if skip_keyword("AUTOINCREMENT")
        @list_of_primary_key_columns = [column.column_name]
        @list_of_primary_key_collations = [nil] of String?
        add_unique_constraint([column.column_name], [IndexDefinition::KeyTerm.new(column.column_name, nil, column.primary_key_descending?)], primary: true)
      elsif skip_keyword("NOT")
        expect_keyword("NULL")
        column.not_null = true
        conflict_clause
      elsif skip_keyword("NULL")
        conflict_clause
      elsif skip_keyword("UNIQUE")
        conflict_clause
        add_unique_constraint([column.column_name], [IndexDefinition::KeyTerm.new(column.column_name, nil)])
      else
        return false
      end
      true
    end

    private def generated_clause(column : ColumnDefinition) : Nil
      expect_keyword("AS")
      skip_parenthesized
      column.generated = if skip_keyword("STORED")
                           ColumnDefinition::Generated::Stored
                         else
                           skip_keyword("VIRTUAL")
                           ColumnDefinition::Generated::Virtual
                         end
    end

    private def default_clause(column : ColumnDefinition) : Nil
      if current.punctuation?('(')
        start = @position
        skip_parenthesized
        column.default_expression = @tokens[start...@position].map(&.text).join(' ')
        return
      end
      sign = 1
      if current.punctuation?('-') || current.punctuation?('+')
        sign = -1 if advance.text == "-"
      end
      token = advance
      if token.kind.number? && !integer_literal?(token.text)
        column.default_real_literal = sign == -1 ? "-#{token.text}" : token.text
      end
      column.default_value = case token.kind
                             when .number? then signed_number(token.text, sign)
                             when .text?
                               column.default_negated_text = sign == -1
                               token.text
                             when .blob? then token.text.hexbytes? || malformed("bad blob literal x'#{token.text}'")
                             else
                               default_keyword(column, token)
                             end
    end

    private def default_keyword(column : ColumnDefinition, token : SchemaTokenizer::Token) : Value
      return if token.keyword?("NULL")
      return 1_i64 if token.keyword?("TRUE")
      return 0_i64 if token.keyword?("FALSE")
      # CURRENT_TIME, CURRENT_DATE, CURRENT_TIMESTAMP and a bare identifier
      # (which SQLite reads as a string) are kept as text to evaluate.
      return token.text if token.kind.identifier?
      column.default_expression = token.text
      nil
    end

    private def integer_literal?(text : String) : Bool
      cleaned = text.delete('_')
      return !cleaned[2..].to_u64?(16).nil? if cleaned.starts_with?("0x") || cleaned.starts_with?("0X")
      !cleaned.to_i64?.nil?
    end

    private def signed_number(text : String, sign : Int32) : Value
      cleaned = text.delete('_')
      if cleaned.starts_with?("0x") || cleaned.starts_with?("0X")
        hex = cleaned[2..].to_u64?(16) || malformed("bad hex literal #{text}")
        return hex.to_i64! &* sign
      end
      if integer = cleaned.to_i64?
        return sign == 1 ? integer : -integer
      end
      # The one integer whose magnitude only fits negated.
      return Int64::MIN if sign == -1 && cleaned == "9223372036854775808"
      real = Affinity.parse_real_literal(cleaned) || malformed("bad number #{text}")
      real * sign
    end

    private def foreign_key_clause : Nil
      name_token
      skip_parenthesized if !at_end? && current.punctuation?('(')
      loop do
        if skip_keyword("ON")
          advance
          if skip_keyword("SET")
            advance
          elsif skip_keyword("NO")
            expect_keyword("ACTION")
          else
            advance
          end
        elsif skip_keyword("MATCH")
          name_token
        elsif current_keyword?("NOT") && peek_keyword?("DEFERRABLE")
          advance
          deferrable_clause
        elsif current_keyword?("DEFERRABLE")
          deferrable_clause
        else
          break
        end
      end
    end

    private def deferrable_clause : Nil
      expect_keyword("DEFERRABLE")
      if skip_keyword("INITIALLY")
        advance
      end
    end

    private def table_constraint_start? : Bool
      return false if at_end? || !current.kind.word?
      TABLE_CONSTRAINT_KEYWORDS.any? { |keyword| current.keyword?(keyword) }
    end

    private def column_constraint_start? : Bool
      return false if at_end? || !current.kind.word?
      COLUMN_CONSTRAINT_KEYWORDS.any? { |keyword| current.keyword?(keyword) }
    end

    # parse.y conslist: after the columns, table constraints follow with
    # or without commas between them.
    private def table_constraints : Nil
      loop do
        table_constraint
        skip_punctuation(',')
        break unless table_constraint_start?
      end
    end

    private def table_constraint : Nil
      if skip_keyword("CONSTRAINT")
        name_token
        # `CONSTRAINT name` alone is a constraint of its own (tcons).
        return unless table_constraint_start?
        return if current.keyword?("CONSTRAINT")
      end
      if skip_keyword("PRIMARY")
        expect_keyword("KEY")
        columns, collations, terms = indexed_columns
        conflict_clause
        @list_of_primary_key_columns = columns
        @list_of_primary_key_collations = collations
        if columns.size == 1
          if index = column_index(columns.first)
            @list_of_columns[index].primary_key = true
          end
        end
        add_unique_constraint(columns, terms, primary: true)
      elsif skip_keyword("UNIQUE")
        columns, _collations, terms = indexed_columns
        conflict_clause
        add_unique_constraint(columns, terms)
      elsif skip_keyword("CHECK")
        skip_parenthesized
      elsif skip_keyword("FOREIGN")
        expect_keyword("KEY")
        skip_parenthesized
        expect_keyword("REFERENCES")
        foreign_key_clause
      else
        malformed("unexpected #{current.text} in a table constraint")
      end
    end

    # Reads `( name [COLLATE x] [ASC|DESC], ... )` and returns the names
    # and the COLLATE written for each (nil when none is).
    private def indexed_columns : {Array(String), Array(String?), Array(IndexDefinition::KeyTerm)}
      expect_punctuation('(')
      names = [] of String
      collations = [] of String?
      terms = [] of IndexDefinition::KeyTerm
      loop do
        name = name_token
        collation = skip_keyword("COLLATE") ? name_token : nil
        descending = !skip_keyword("ASC") && skip_keyword("DESC")
        names << name
        collations << collation
        terms << IndexDefinition::KeyTerm.new(name, collation, descending)
        break unless skip_punctuation(',')
      end
      expect_punctuation(')')
      {names, collations, terms}
    end

    # The collation the primary key applies to its *position*th column.
    def primary_key_collation(position : Int32) : String
      explicit = @list_of_primary_key_collations[position]?
      return explicit if explicit
      index = column_index(@list_of_primary_key_columns[position])
      index ? @list_of_columns[index].collation : "BINARY"
    end

    # PRIMARY KEY and UNIQUE constraints in the order written; the automatic
    # indexes are settled once the whole statement is read.
    private def add_unique_constraint(columns : Array(String), terms : Array(IndexDefinition::KeyTerm), *, primary : Bool = false) : Nil
      @list_of_written_constraints << {columns, terms, primary}
    end

    # SQLite skips an automatic index whose columns repeat an earlier one
    # (sqlite3CreateIndex), and numbers the rest in order.
    private def add_automatic_index(columns : Array(String), terms : Array(IndexDefinition::KeyTerm)) : Nil
      lowered = columns.map(&.downcase)
      return if @list_of_unique_constraints.any? { |existing| existing.map(&.downcase) == lowered }
      @list_of_unique_constraints << columns
      @list_of_unique_constraint_terms << terms
    end

    private def conflict_clause : Nil
      return unless current_keyword?("ON") && peek_keyword?("CONFLICT")
      advance
      advance
      advance
    end

    private def table_options : Nil
      loop do
        if skip_keyword("WITHOUT")
          expect_keyword("ROWID")
          @without_rowid = true
        elsif skip_keyword("STRICT")
          @strict = true
          @list_of_columns.each do |column|
            column.affinity = Affinity::Blob if column.declared_type.compare("ANY", case_insensitive: true) == 0
          end
        else
          break
        end
        break unless skip_punctuation(',')
      end
      skip_punctuation(';')
      malformed("unexpected #{current.text} after the column list") unless at_end?
    end

    # lang_createtable.html, "ROWID and the INTEGER PRIMARY KEY": a single
    # primary key column whose declared type is exactly INTEGER aliases the
    # rowid, except when declared "INTEGER PRIMARY KEY DESC" as a column
    # constraint, and never in a WITHOUT ROWID table. Such a key makes no
    # index of its own (sqlite3AddPrimaryKey), so a UNIQUE constraint on the
    # same column keeps its automatic index; in a WITHOUT ROWID table the
    # key's index is made only at the end of the statement
    # (convertToWithoutRowidTable), after every UNIQUE constraint.
    private def resolve_rowid_alias : Nil
      written = @list_of_written_constraints
      candidate = integer_primary_key_candidate
      if candidate && !@without_rowid
        @rowid_alias_index = candidate
        written = written.reject { |_columns, _terms, primary| primary }
      elsif candidate
        written = written.reject { |_columns, _terms, primary| primary } + written.select { |_columns, _terms, primary| primary }
      end
      written.each { |columns, terms, _primary| add_automatic_index(columns, terms) }
    end

    private def integer_primary_key_candidate : Int32?
      return if @list_of_primary_key_columns.size != 1
      index = column_index(@list_of_primary_key_columns.first)
      return unless index
      column = @list_of_columns[index]
      return unless column.declared_type.compare("INTEGER", case_insensitive: true) == 0
      return if column.primary_key_descending?
      index
    end

    private def qualified_name : String
      name = name_token
      if skip_punctuation('.')
        name = name_token
      end
      name
    end

    private def name_token : String
      malformed("expected a name at the end of the statement") if at_end?
      token = advance
      malformed("expected a name, found #{token.text}") unless token.name?
      token.text
    end

    private def skip_parenthesized : Nil
      expect_punctuation('(')
      depth = 1
      while depth > 0
        malformed("unbalanced parentheses") if at_end?
        token = advance
        depth += 1 if token.punctuation?('(')
        depth -= 1 if token.punctuation?(')')
      end
    end

    private def current : SchemaTokenizer::Token
      malformed("statement ends early") if at_end?
      @tokens[@position]
    end

    private def at_end? : Bool
      @position >= @tokens.size
    end

    private def advance : SchemaTokenizer::Token
      token = current
      @position += 1
      token
    end

    private def current_keyword?(keyword : String) : Bool
      !at_end? && current.keyword?(keyword)
    end

    private def peek_keyword?(keyword : String) : Bool
      next_token = @tokens[@position + 1]?
      !next_token.nil? && next_token.keyword?(keyword)
    end

    private def skip_keyword(keyword : String) : Bool
      return false unless current_keyword?(keyword)
      @position += 1
      true
    end

    private def expect_keyword(keyword : String) : Nil
      malformed("expected #{keyword}") unless skip_keyword(keyword)
    end

    private def skip_punctuation(char : Char) : Bool
      return false if at_end? || !current.punctuation?(char)
      @position += 1
      true
    end

    private def expect_punctuation(char : Char) : Nil
      malformed("expected #{char}") unless skip_punctuation(char)
    end

    private def malformed(message : String) : NoReturn
      raise SchemaTokenizer::Malformed.new(message)
    end
  end
end
