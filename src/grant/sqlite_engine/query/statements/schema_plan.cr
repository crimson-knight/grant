module Grant::SQLiteEngine::Query
  class Compiler
    # The whole plan of a top-level SELECT, for CREATE TABLE ... AS SELECT
    # (its column names and affinities) and the frame size it needs.
    def compile_plan(statement : SQL::SelectStatement) : {QueryPlan, Int32, Int32}
      plan = compile_query(statement, nil, nil)
      {plan, @slot_count, @aggregate_count}
    end
  end

  # CREATE TABLE, CREATE INDEX, CREATE VIEW, DROP and ALTER TABLE
  # (lang_createtable.html, lang_createindex.html, lang_createview.html,
  # lang_droptable.html, lang_altertable.html). Each runs as a write
  # statement and leaves the session's schema cache empty.
  class SchemaPlan < StatementPlan
    def initialize(@session : Session, @statement : SQL::Statement, @text : String)
      statement = @statement
      case statement
      when SQL::CreateTable
        raise UnsupportedSQL.new("TEMP tables (the temp schema)") if statement.temporary
        check_schema_name(statement.schema)
      when SQL::CreateIndex
        check_schema_name(statement.schema)
      when SQL::CreateView
        raise UnsupportedSQL.new("TEMP views (the temp schema)") if statement.temporary
        check_schema_name(statement.schema)
      when SQL::Drop
        check_schema_name(statement.schema)
        if statement.kind.trigger?
          raise SQLError.new("no such trigger: #{statement.name.value}") unless statement.if_exists
        end
      when SQL::AlterTable
        check_schema_name(statement.schema)
      when SQL::CreateTrigger
        raise UnsupportedSQL.new("triggers (CREATE TRIGGER)")
      when SQL::CreateVirtualTable
        raise UnsupportedSQL.new("virtual tables (CREATE VIRTUAL TABLE)")
      end
    end

    private def check_schema_name(schema : SQL::Name?) : Nil
      return unless schema
      return if schema.same?("main")
      raise UnsupportedSQL.new("the temp schema") if schema.same?("temp")
      raise SQLError.new("unknown database #{schema.value}")
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      statement = @statement
      # sqlite3FkDropTable runs a DELETE first, which sets changes().
      counts = statement.is_a?(SQL::Drop) && statement.kind.table? && @session.foreign_keys? &&
               !@session.list_of_child_tables(statement.name.value).empty? && !@session.table(statement.name.value).nil?
      @session.run_write(list_of_parameters, counts_changes: counts) do |run|
        begin
          case statement
          when SQL::CreateTable then create_table(statement, run)
          when SQL::CreateIndex then create_index(statement, run)
          when SQL::CreateView  then create_view(statement)
          when SQL::Drop        then drop(statement, run)
          when SQL::AlterTable  then SchemaAlteration.new(@session, run, statement, @text).perform
          end
        rescue error : SchemaError
          raise SQLError.new(error.message || "schema error")
        rescue error : ConstraintViolation
          raise ConstraintError.new(error.message || "constraint failed")
        end
      end
      @session.reset_schema
      [] of Array(Value)
    end

    private def database : Database
      @session.database
    end

    private def entry_named(name : String) : SchemaEntry?
      return if database.page_count == 0
      database.schema.list_of_entries.find { |entry| entry.object_name.compare(name, case_insensitive: true) == 0 }
    end

    # *written* is the name as the statement wrote it: sqlite3StartTable
    # reports a table or view that exists with %T, quotes and all.
    private def check_new_object(name : String, written : String, if_not_exists : Bool, kind : String) : Bool
      if existing = entry_named(name)
        return false if if_not_exists && existing.object_type == kind
        if existing.index?
          raise SQLError.new(kind == "index" ? "index #{name} already exists" : "there is already an index named #{name}")
        end
        if kind == "index"
          raise SQLError.new("there is already a table named #{name}")
        end
        raise SQLError.new("#{existing.object_type == "view" ? "view" : "table"} #{written} already exists")
      end
      if name.downcase.starts_with?("sqlite_")
        raise SQLError.new("object name reserved for internal use: #{name}")
      end
      true
    end

    private def create_table(statement : SQL::CreateTable, run : WriteRun) : Nil
      name = statement.name.value
      return unless check_new_object(name, statement.name.text, statement.if_not_exists, "table")
      if query = statement.as_select
        create_table_as(name, query, run)
        return
      end
      database.create_table(@text)
    end

    # CREATE TABLE ... AS SELECT: columns named and typed from the query
    # (createTableStmt), filled with its rows.
    private def create_table_as(name : String, query : SQL::SelectStatement, run : WriteRun) : Nil
      compiler = Compiler.new(@session)
      plan, slot_count, aggregate_count = compiler.compile_plan(query)
      names = Compiler.unique_names(plan.list_of_subquery_names || plan.list_of_column_names)
      sql = SchemaPlan.create_table_text(name, names, plan.list_of_column_affinities)
      database.create_table(sql)
      @session.reset_schema
      frame = Frame.new(slot_count, aggregate_count, run.list_of_parameters, @session)
      plan.producer.open(frame)
      rows = [] of Array(Value)
      while row = plan.producer.next_row(frame)
        rows << row
      end
      table = run.table(name)
      run.silent = true
      begin
        rows.each { |row| run.insert_row(table, row.dup, nil, ConflictAction::Abort) }
      ensure
        run.silent = false
      end
    end

    TYPE_WORDS = {
      ExpressionAffinity::None    => "",
      ExpressionAffinity::Blob    => "",
      ExpressionAffinity::Text    => " TEXT",
      ExpressionAffinity::Numeric => " NUM",
      ExpressionAffinity::Integer => " INT",
      ExpressionAffinity::Real    => " REAL",
      ExpressionAffinity::FlexNum => " NUM",
    }

    # createTableStmt of build.c.
    def self.create_table_text(name : String, names : Array(String), affinities : Array(ExpressionAffinity)) : String
      size = names.sum { |column| identifier_length(column) + 5 } + identifier_length(name)
      separator, next_separator, finish = size < 50 ? {"", ",", ")"} : {"\n  ", ",\n  ", "\n)"}
      String.build do |io|
        io << "CREATE TABLE " << identifier(name) << '('
        names.each_with_index do |column, index|
          io << (index == 0 ? separator : next_separator)
          io << identifier(column) << TYPE_WORDS[affinities[index]? || ExpressionAffinity::None]
        end
        io << finish
      end
    end

    private def self.identifier_length(text : String) : Int32
      text.count('"') + text.size + 2
    end

    # identPut: quoted unless it is a plain word that is not a keyword.
    def self.identifier(text : String) : String
      plain = !text.empty? && !text[0].ascii_number? && text.each_char.all? { |char| char.ascii_alphanumeric? || char == '_' || char.ord >= 0x80 }
      plain &&= !SQL::Keywords::TABLE.has_key?(text.upcase)
      plain ? text : %("#{text.gsub('"', "\"\"")}")
    end

    private def create_index(statement : SQL::CreateIndex, run : WriteRun) : Nil
      name = statement.name.value
      table_name = statement.table.value
      if @session.view(table_name)
        raise SQLError.new("views may not be indexed")
      end
      unless @session.table(table_name)
        raise SQLError.new("no such table: main.#{table_name}")
      end
      if table_name.downcase.starts_with?("sqlite_")
        raise SQLError.new("table #{table_name} may not be indexed")
      end
      info = @session.table(table_name) || raise SQLError.new("no such table: main.#{table_name}")
      statement.columns.each do |term|
        expression = term.expression
        while expression.is_a?(SQL::Collate)
          expression = expression.operand
        end
        if expression.is_a?(SQL::ColumnReference) && expression.table.nil? && info.column_index(expression.column.value).nil?
          unless RowidName.rowid?(info, expression.column.value)
            # A double-quoted name that is no column reads as a string
            # (DQS in DDL), which makes an expression index.
            if expression.column.text.starts_with?('"')
              raise UnsupportedSQL.new("expression in index #{name} (the string #{expression.column.text})")
            end
            raise SQLError.new("no such column: #{expression.column.value}")
          end
        end
      end
      return unless check_new_object(name, statement.name.text, statement.if_not_exists, "index")
      database.create_index_from(@text, run)
    end

    private def create_view(statement : SQL::CreateView) : Nil
      name = statement.name.value
      return unless check_new_object(name, statement.name.text, statement.if_not_exists, "view")
      database.add_schema_row("view", name, name, 0_u32, "CREATE VIEW #{SchemaPlan.text_from_name(@text, statement.name)}")
      database.note_schema_change
    end

    # The statement text from the object's (unqualified) name on, as
    # sqlite3EndTable stores it after "CREATE TABLE " or "CREATE VIEW ".
    def self.text_from_name(text : String, name : SQL::Name) : String
      tokenizer = SQL::Tokenizer.new(text)
      start = 0
      loop do
        token = tokenizer.next_token
        break if token.kind.end_of_input? || token.kind.illegal? || token.kind == SQL::TokenKind::As || token.kind.left_paren?
        start = token.start if tokenizer.text(token) == name.text
      end
      text.byte_slice(start)
    end

    private def drop(statement : SQL::Drop, run : WriteRun) : Nil
      name = statement.name.value
      entry = entry_named(name)
      case statement.kind
      when .table?
        unless entry && entry.table?
          if entry && entry.object_type == "view"
            raise SQLError.new("use DROP VIEW to delete view #{name}")
          end
          return if statement.if_exists
          raise SQLError.new("no such table: #{name}")
        end
        if name.downcase.starts_with?("sqlite_")
          raise SQLError.new("table #{entry.object_name} may not be dropped")
        end
        drop_table_rows(entry.object_name, run) if @session.foreign_keys?
        database.drop(entry.object_name)
      when .view?
        unless entry && entry.object_type == "view"
          if entry && entry.table?
            raise SQLError.new("use DROP TABLE to delete table #{name}")
          end
          return if statement.if_exists
          raise SQLError.new("no such view: #{name}")
        end
        view_name = entry.object_name
        database.delete_schema_rows { |record| record[0]? == "view" && record[1]? == view_name }
      when .index?
        unless entry && entry.index?
          return if statement.if_exists
          raise SQLError.new("no such index: #{name}")
        end
        database.drop(entry.object_name)
      end
    end

    # sqlite3FkDropTable: with foreign keys on, dropping a parent table
    # first deletes its rows (running the children's actions); a child row
    # left without its parent fails the DROP.
    private def drop_table_rows(name : String, run : WriteRun) : Nil
      return if @session.list_of_child_tables(name).empty?
      table = run.table(name)
      rows = [] of {Int64?, Array(Value)}
      run.cursor_rows(table) { |rowid, row| rows << {rowid, row} }
      rows.each { |rowid, row| run.delete_row(table, rowid, row) }
      unless @session.defer_foreign_keys?
        raise ConstraintError.new("FOREIGN KEY constraint failed") if run.immediate_violations > 0
      end
    end
  end
end
