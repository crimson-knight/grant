module Grant::SQLiteEngine::Query
  # ALTER TABLE: RENAME TO, RENAME COLUMN, ADD COLUMN and DROP COLUMN
  # (lang_altertable.html). The stored CREATE statements are edited token
  # by token as alter.c's sqlite_rename_* functions edit them, so the text
  # in sqlite_schema matches C's.
  class SchemaAlteration
    TABLE_CONSTRAINT_STARTS = %w[CONSTRAINT PRIMARY UNIQUE CHECK FOREIGN]

    # A token of a stored statement: its kind, byte offset, size and text.
    record SourceToken, kind : SQL::TokenKind, start : Int32, size : Int32, text : String do
      def finish : Int32
        start + size
      end

      def same_name?(name : String) : Bool
        (kind.identifier? || kind.string? || SQL::Keywords.falls_back_to_identifier?(kind)) &&
          SQL::Parser.dequote(text).compare(name, case_insensitive: true) == 0
      end

      def quoted? : Bool
        !text.empty? && text[0].in?('"', '`', '[', '\'')
      end
    end

    def initialize(@session : Session, @run : WriteRun, @statement : SQL::AlterTable, @text : String)
    end

    private def database : Database
      @session.database
    end

    def perform : Nil
      name = @statement.table.value
      entry = database.page_count == 0 ? nil : database.schema.list_of_entries.find { |candidate| candidate.object_name.compare(name, case_insensitive: true) == 0 }
      if entry && entry.object_type == "view"
        raise SQLError.new("view #{entry.object_name} may not be altered")
      end
      raise SQLError.new("no such table: #{name}") unless entry && entry.table?
      if entry.object_name.downcase.starts_with?("sqlite_")
        raise SQLError.new("table #{entry.object_name} may not be altered")
      end
      action = @statement.action
      case action
      when SQL::RenameTable  then rename_table(entry, action.new_name)
      when SQL::RenameColumn then rename_column(entry, action.old_name.value, action.new_name)
      when SQL::AddColumn    then add_column(entry, action.column)
      when SQL::DropColumn   then drop_column(entry, action.column_name.value)
      end
      @session.reset_schema
    end

    def self.tokens(sql : String) : Array(SourceToken)
      tokenizer = SQL::Tokenizer.new(sql)
      list = [] of SourceToken
      loop do
        token = tokenizer.next_token
        break if token.kind.end_of_input? || token.kind.illegal?
        list << SourceToken.new(token.kind, token.start, token.size, tokenizer.text(token))
      end
      list
    end

    # *sql* with each token the block names replaced by the block's text.
    def self.edit(sql : String, tokens : Array(SourceToken), replacements : Hash(Int32, String)) : String
      return sql if replacements.empty?
      String.build do |io|
        position = 0
        tokens.each_with_index do |token, index|
          replacement = replacements[index]?
          next unless replacement
          io << sql.byte_slice(position, token.start - position)
          io << replacement
          position = token.finish
        end
        io << sql.byte_slice(position)
      end
    end

    def self.quoted(name : String) : String
      %("#{name.gsub('"', "\"\"")}")
    end

    # --- RENAME TO ----------------------------------------------------------

    private def rename_table(entry : SchemaEntry, new_name : SQL::Name) : Nil
      old_name = entry.object_name
      target = new_name.value
      if database.schema.list_of_entries.any? { |other| other.object_name.compare(target, case_insensitive: true) == 0 }
        raise SQLError.new("there is already another table or index with this name: #{target}")
      end
      raise SQLError.new("object name reserved for internal use: #{target}") if target.downcase.starts_with?("sqlite_")
      replacement = SchemaAlteration.quoted(target)
      database.rewrite_schema_rows do |record|
        type, name, table_name, root, sql = record[0]?, record[1]?, record[2]?, record[3]?, record[4]?
        next unless type.is_a?(String) && name.is_a?(String) && table_name.is_a?(String)
        own = table_name.compare(old_name, case_insensitive: true) == 0
        new_sql = sql.is_a?(String) ? rename_in(sql, type, old_name, replacement, own) : sql
        new_object = name
        new_table = table_name
        if own
          new_table = target
          if type == "table"
            new_object = target
          elsif type == "index" && name.starts_with?("sqlite_autoindex_#{old_name}_")
            new_object = "sqlite_autoindex_#{target}_#{name.rpartition('_').last}"
          end
        end
        next if new_sql == sql && new_object == name && new_table == table_name
        [type, new_object, new_table, root, new_sql] of Value
      end
      if database.sequence_of(old_name)
        sequence_entry = database.schema.list_of_entries.find { |candidate| candidate.object_name == Database::SEQUENCE_TABLE }
        if sequence_entry
          rows = [] of {Int64, Array(Value)}
          database.each_table_btree_record(sequence_entry.root_page) do |rowid, values|
            rows << {rowid, values} if values[0]?.as?(String).try(&.compare(old_name, case_insensitive: true)) == 0
          end
          rows.each do |rowid, values|
            database.tree_writer.table_insert(sequence_entry.root_page, rowid,
              RecordEncoder.encode([target, values[1]?] of Value, database.text_encoding))
          end
        end
      end
    end

    # The stored statement with references to the table *old_name* renamed.
    private def rename_in(sql : String, type : String, old_name : String, replacement : String, own : Bool) : String
      tokens = SchemaAlteration.tokens(sql)
      replacements = {} of Int32 => String
      tokens.each_with_index do |token, index|
        next unless token.same_name?(old_name)
        previous = index > 0 ? tokens[index - 1] : nil
        following = tokens[index + 1]?
        named = case
                when previous.nil?                     then false
                when previous.kind.table? && own       then type == "table"
                when previous.kind.exists? && own      then type == "table"
                when previous.kind.references?         then true
                when previous.kind.on? && own          then type == "index"
                when type == "view"
                  previous.kind.from? || previous.kind.join_keyword? || previous.kind.join? ||
                    (previous.kind.comma? && view_from_list?(tokens, index)) || following.try(&.kind.dot?) || false
                else
                  false
                end
        replacements[index] = replacement if named
      end
      SchemaAlteration.edit(sql, tokens, replacements)
    end

    # True when the comma before *index* separates FROM items.
    private def view_from_list?(tokens : Array(SourceToken), index : Int32) : Bool
      depth = 0
      position = index - 1
      while position >= 0
        token = tokens[position]
        depth += 1 if token.kind.right_paren?
        depth -= 1 if token.kind.left_paren?
        return false if depth < 0
        if depth == 0
          return true if token.kind.from?
          return false if token.kind.select? || token.kind.where? || token.kind.on?
        end
        position -= 1
      end
      false
    end

    # --- RENAME COLUMN ------------------------------------------------------

    private def rename_column(entry : SchemaEntry, old_column : String, new_name : SQL::Name) : Nil
      info = @session.table(entry.object_name) || raise SQLError.new("no such table: #{entry.object_name}")
      position = info.column_index(old_column)
      raise SQLError.new(%(no such column: "#{old_column}")) unless position
      target = new_name.value
      if info.list_of_column_names.each_with_index.any? { |column, index| index != position && column.compare(target, case_insensitive: true) == 0 }
        raise SQLError.new("error in table #{entry.object_name} after rename: duplicate column name: #{target}")
      end
      new_quoted = new_name.text != new_name.value || new_name.text.empty? || new_name.text[0].in?('"', '`', '[', '\'')
      table_name = entry.object_name
      database.rewrite_schema_rows do |record|
        type, name, record_table, root, sql = record[0]?, record[1]?, record[2]?, record[3]?, record[4]?
        next unless type.is_a?(String) && sql.is_a?(String) && record_table.is_a?(String)
        own = record_table.compare(table_name, case_insensitive: true) == 0
        new_sql = if own && type == "table"
                    column_in_table(sql, old_column, target, new_quoted, table_name)
                  elsif own && type == "index"
                    column_in_index(sql, old_column, target, new_quoted)
                  elsif type == "table"
                    column_in_references(sql, table_name, old_column, target, new_quoted)
                  elsif type == "view"
                    column_in_view(sql, table_name, old_column, target, new_quoted)
                  else
                    sql
                  end
        next if new_sql == sql
        [type, name, record_table, root, new_sql] of Value
      end
    end

    private def column_replacement(token : SourceToken, target : String, new_quoted : Bool) : String
      plain = !new_quoted && !token.quoted? && SchemaPlan.identifier(target) == target
      plain ? target : SchemaAlteration.quoted(target)
    end

    # Column names in the table's own CREATE: each column-name position at
    # the top of the column list, and names inside constraint expressions
    # and key lists (not inside REFERENCES to another table).
    private def column_in_table(sql : String, old_column : String, target : String, new_quoted : Bool, table_name : String) : String
      tokens = SchemaAlteration.tokens(sql)
      replacements = {} of Int32 => String
      depth = 0
      column_start = false
      foreign_depth = -1
      tokens.each_with_index do |token, index|
        case token.kind
        when .left_paren?
          depth += 1
          column_start = depth == 1
          next
        when .right_paren?
          foreign_depth = -1 if depth == foreign_depth
          depth -= 1
          next
        when .comma?
          column_start = depth == 1
          next
        end
        if token.kind.references?
          referenced = tokens[index + 1]?
          foreign_depth = referenced && !referenced.same_name?(table_name) ? depth + 1 : -1
        end
        if depth == 1 && column_start
          replacements[index] = column_replacement(token, target, new_quoted) if token.same_name?(old_column)
          column_start = false
          next
        end
        next if depth < 2 || (foreign_depth > 0 && depth >= foreign_depth)
        replacements[index] = column_replacement(token, target, new_quoted) if token.same_name?(old_column)
      end
      SchemaAlteration.edit(sql, tokens, replacements)
    end

    # Column names in an index of the table: its key list and WHERE.
    private def column_in_index(sql : String, old_column : String, target : String, new_quoted : Bool) : String
      tokens = SchemaAlteration.tokens(sql)
      replacements = {} of Int32 => String
      on = tokens.index(&.kind.on?) || return sql
      tokens.each_with_index do |token, index|
        next if index <= on + 1
        replacements[index] = column_replacement(token, target, new_quoted) if token.same_name?(old_column)
      end
      SchemaAlteration.edit(sql, tokens, replacements)
    end

    # Column references in a view that reads the table (renameColumnFunc
    # walks the view's SELECT; names used as aliases or functions stay).
    private def column_in_view(sql : String, table_name : String, old_column : String, target : String, new_quoted : Bool) : String
      tokens = SchemaAlteration.tokens(sql)
      return sql unless tokens.any?(&.same_name?(table_name))
      replacements = {} of Int32 => String
      tokens.each_with_index do |token, index|
        next unless token.same_name?(old_column)
        previous = index > 0 ? tokens[index - 1] : nil
        next if previous && (previous.kind == SQL::TokenKind::As || previous.kind.view?)
        next if tokens[index + 1]?.try(&.kind.left_paren?)
        replacements[index] = column_replacement(token, target, new_quoted)
      end
      SchemaAlteration.edit(sql, tokens, replacements)
    end

    # `REFERENCES table(old)` in another table's CREATE.
    private def column_in_references(sql : String, table_name : String, old_column : String, target : String, new_quoted : Bool) : String
      tokens = SchemaAlteration.tokens(sql)
      replacements = {} of Int32 => String
      tokens.each_with_index do |token, index|
        next unless token.kind.references? && tokens[index + 1]?.try(&.same_name?(table_name))
        open = tokens[index + 2]?
        next unless open && open.kind.left_paren?
        position = index + 3
        while (inner = tokens[position]?) && !inner.kind.right_paren?
          replacements[position] = column_replacement(inner, target, new_quoted) if inner.same_name?(old_column)
          position += 1
        end
      end
      SchemaAlteration.edit(sql, tokens, replacements)
    end

    # --- ADD COLUMN ---------------------------------------------------------

    private def add_column(entry : SchemaEntry, column : SQL::ColumnDefinition) : Nil
      info = @session.table(entry.object_name) || raise SQLError.new("no such table: #{entry.object_name}")
      name = column.name.value
      if info.column_index(name)
        raise SQLError.new("duplicate column name: #{name}")
      end
      constraints = column.constraints
      if constraints.any?(SQL::PrimaryKeyColumnConstraint)
        raise SQLError.new("Cannot add a PRIMARY KEY column")
      end
      if constraints.any?(SQL::UniqueColumnConstraint)
        raise SQLError.new("Cannot add a UNIQUE column")
      end
      default = constraints.find(&.is_a?(SQL::DefaultConstraint)).as?(SQL::DefaultConstraint)
      generated = constraints.find(&.is_a?(SQL::GeneratedConstraint)).as?(SQL::GeneratedConstraint)
      has_rows = false
      @run.cursor_rows(@run.table(entry.object_name)) { |_rowid, _row| has_rows = true; break }
      if has_rows
        if generated && generated.storage.try(&.same?("STORED"))
          raise SQLError.new("cannot add a STORED column")
        end
        default_null = default.nil? || (default.value.is_a?(SQL::Literal) && default.value.as(SQL::Literal).kind.null?)
        if constraints.any?(SQL::NotNullConstraint) && default_null && generated.nil?
          raise SQLError.new("Cannot add a NOT NULL column with default value NULL")
        end
        if default && !SchemaAlteration.constant_default?(default)
          raise SQLError.new("Cannot add a column with non-constant default")
        end
        if @session.foreign_keys? && constraints.any?(SQL::ReferencesConstraint) && !default_null
          raise SQLError.new("Cannot add a REFERENCES column with non-NULL default value")
        end
      end
      sql = entry.sql || raise SQLError.new("table #{entry.object_name} has no CREATE statement")
      column_text = column_definition_text
      offset = SchemaAlteration.column_list_end(sql)
      new_sql = "#{sql.byte_slice(0, offset)}, #{column_text}#{sql.byte_slice(offset)}"
      table_name = entry.object_name
      database.rewrite_schema_rows do |record|
        next unless record[0]? == "table" && record[1]? == table_name
        [record[0]?, record[1]?, record[2]?, record[3]?, new_sql] of Value
      end
    end

    # A default ALTER TABLE ADD COLUMN accepts: a literal, a signed number,
    # or a name read as a string (sqlite3ValueFromExpr succeeds).
    def self.constant_default?(default : SQL::DefaultConstraint) : Bool
      value = default.value
      while value.is_a?(SQL::UnaryOperation) && (value.operator.negate? || value.operator.plus?)
        value = value.operand
      end
      return true if value.is_a?(SQL::ColumnReference)
      value.is_a?(SQL::Literal) && !value.kind.current_time? && !value.kind.current_date? && !value.kind.current_timestamp? &&
        !default.form.parenthesized?
    end

    # The column definition as the ALTER statement wrote it, from its name.
    private def column_definition_text : String
      tokens = SchemaAlteration.tokens(@text)
      add = tokens.index(&.kind.add?) || raise Error.new("ADD COLUMN without ADD")
      start = add + 1
      start += 1 if tokens[start]?.try(&.kind.column?)
      first = tokens[start]? || raise Error.new("ADD COLUMN without a column")
      @text.byte_slice(first.start).rstrip.rstrip(';').rstrip
    end

    # addColOffset: where the column list ends in a stored CREATE TABLE,
    # the comma before the first table constraint or the closing
    # parenthesis.
    def self.column_list_end(sql : String) : Int32
      tokens = tokens(sql)
      depth = 0
      tokens.each_with_index do |token, index|
        case token.kind
        when .left_paren?
          depth += 1
        when .right_paren?
          depth -= 1
          return token.start if depth == 0
        when .comma?
          if depth == 1 && (following = tokens[index + 1]?) && TABLE_CONSTRAINT_STARTS.includes?(following.text.upcase)
            return token.start
          end
        end
      end
      sql.bytesize
    end

    # --- DROP COLUMN --------------------------------------------------------

    private def drop_column(entry : SchemaEntry, column_name : String) : Nil
      table = @run.table(entry.object_name)
      info = table.table_info
      position = info.column_index(column_name)
      raise SQLError.new(%(no such column: "#{column_name}")) unless position
      actual = info.list_of_column_names[position]
      definition = info.definition
      if definition.list_of_primary_key_columns.any? { |key| key.compare(actual, case_insensitive: true) == 0 }
        raise SQLError.new(%(cannot drop PRIMARY KEY column: "#{actual}"))
      end
      if definition.list_of_unique_constraints.any? { |columns| columns.any? { |key| key.compare(actual, case_insensitive: true) == 0 } }
        raise SQLError.new(%(cannot drop UNIQUE column: "#{actual}"))
      end
      if info.list_of_column_names.size == 1
        raise SQLError.new(%(cannot drop column "#{actual}": no other columns exist))
      end
      sql = entry.sql || raise SQLError.new("table #{entry.object_name} has no CREATE statement")
      new_sql = SchemaAlteration.without_column(sql, position)
      table_name = entry.object_name
      rows = [] of {Int64?, Array(Value)}
      @run.cursor_rows(table) { |rowid, row| rows << {rowid, row} }
      database.rewrite_schema_rows do |record|
        next unless record[0]? == "table" && record[1]? == table_name
        [record[0]?, record[1]?, record[2]?, record[3]?, new_sql] of Value
      end
      @session.reset_schema
      check_after_drop(table_name, actual)
      layout = database.write_layout(table_name)
      raise UnsupportedSQL.new("DROP COLUMN of a WITHOUT ROWID table") if layout.definition.without_rowid?
      rows.each do |rowid, row|
        row.delete_at(position)
        database.write_row(layout, rowid, database.stored_values(layout.definition, row), [] of IndexLayout)
      end
    end

    # C re-parses the schema after the edit; an index, CHECK, foreign key
    # or view that names the dropped column fails the statement.
    private def check_after_drop(table_name : String, column_name : String) : Nil
      info = @session.table(table_name) || return
      info.list_of_indexes.each do |index|
        sql = index.entry.sql
        next unless sql
        if SchemaAlteration.tokens(sql).any?(&.same_name?(column_name))
          raise SQLError.new("error in index #{index.entry.object_name} after drop column: no such column: #{column_name}")
        end
      end
      sql = info.entry.sql || return
      statement = SQL::Parser.parse_schema(sql)
      if statement.is_a?(SQL::CreateTable)
        statement.constraints.each do |constraint|
          case constraint
          when SQL::CheckTableConstraint
            if constraint.expression.to_sql.downcase.includes?(column_name.downcase) &&
               SchemaAlteration.tokens(constraint.expression.to_sql).any?(&.same_name?(column_name))
              raise SQLError.new("error in table #{table_name} after drop column: no such column: #{column_name}")
            end
          when SQL::ForeignKeyTableConstraint
            if constraint.columns.any?(&.same?(column_name))
              raise SQLError.new(%(error in table #{table_name} after drop column: unknown column "#{column_name}" in foreign key definition))
            end
          end
        end
      end
      database.schema.list_of_entries.each do |entry|
        next unless entry.object_type == "view"
        view = @session.view(entry.object_name) || next
        begin
          Compiler.new(@session).compile(view.query)
        rescue error : SQLError
          raise SQLError.new("error in view #{entry.object_name} after drop column: #{error.message}")
        end
      end
    end

    # The CREATE TABLE text without column *position* (sqlite3AlterDropColumn).
    def self.without_column(sql : String, position : Int32) : String
      tokens = tokens(sql)
      starts = [] of Int32
      depth = 0
      column_start = false
      list_end = column_list_end(sql)
      tokens.each do |token|
        case token.kind
        when .left_paren?
          depth += 1
          column_start = depth == 1
          next
        when .right_paren?
          depth -= 1
          next
        when .comma?
          column_start = depth == 1
          next
        end
        if depth == 1 && column_start
          starts << token.start if token.start < list_end
          column_start = false
        end
      end
      start = starts[position]? || return sql
      if position < starts.size - 1
        finish = starts[position + 1]
        return "#{sql.byte_slice(0, start)}#{sql.byte_slice(finish)}"
      end
      comma = sql.byte_slice(0, start).rindex(',') || start
      "#{sql.byte_slice(0, comma)}#{sql.byte_slice(list_end)}"
    end
  end
end
