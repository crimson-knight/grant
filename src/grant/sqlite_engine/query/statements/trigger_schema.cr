module Grant::SQLiteEngine::Query
  # CREATE TRIGGER and DROP TRIGGER (lang_createtrigger.html,
  # lang_droptrigger.html), with sqlite3BeginTrigger's checks and the
  # sqlite_schema row sqlite3FinishTrigger writes.
  class SchemaPlan
    private def create_trigger(statement : SQL::CreateTrigger) : Nil
      trigger_name = statement.name.value
      database = trigger_database(statement)
      temporary = database.same?(@session.temp_database)
      table_name = statement.table.value
      table_schema = statement.table_schema
      if table_schema && !temporary && !@session.existing_database_named(table_schema.value).same?(database)
        raise SQLError.new("trigger #{trigger_name} cannot reference objects in database #{table_schema.value}")
      end
      table, view = trigger_target(statement, database, temporary)
      written = temporary && table_schema ? "#{table_schema.value}.#{table_name}" : table_name
      unless table || view
        raise SQLError.new("no such table: #{written}") if temporary && table_schema.nil?
        raise SQLError.new("no such table: #{temporary ? table_schema.try(&.value) : @session.schema_name_of(database)}.#{table_name}")
      end
      if trigger_name.downcase.starts_with?("sqlite_")
        raise SQLError.new("object name reserved for internal use: #{trigger_name}")
      end
      if @session.trigger_named(trigger_name, database)
        return if statement.if_not_exists
        raise SQLError.new("trigger #{statement.name.text} already exists")
      end
      target_name = table.try(&.name) || view.try(&.name) || table_name
      raise SQLError.new("cannot create trigger on system table") if target_name.downcase.starts_with?("sqlite_")
      instead_of = statement.time.instead_of?
      if view && !instead_of
        raise SQLError.new("cannot create #{statement.time.after? ? "AFTER" : "BEFORE"} trigger on view: #{written}")
      end
      if table && instead_of
        raise SQLError.new("cannot create INSTEAD OF trigger on table: #{written}")
      end
      raise SQLError.new("trigger cannot use variables") if SchemaPlan.uses_variables?(@text)
      check_body_schemas(statement, database) unless temporary
      database.add_schema_row("trigger", trigger_name, table_name, 0_u32, "CREATE TRIGGER #{SchemaPlan.trigger_text(@text)}")
      database.note_schema_change
    end

    private def check_body_schemas(statement : SQL::CreateTrigger, database : Database) : Nil
      statement.body.each do |step|
        TriggerSchemaNames.each_schema(step) do |schema|
          next if @session.existing_database_named(schema).same?(database)
          raise SQLError.new("trigger #{statement.name.value} cannot reference objects in database #{schema}")
        end
      end
    end

    # The database the trigger goes in: temp for TEMP, the one its name
    # gives, else main, or temp when an unqualified name's table is a
    # TEMP table.
    private def trigger_database(statement : SQL::CreateTrigger) : Database
      return @session.temp_database! if statement.temporary
      if schema = statement.schema
        return @session.database_named(schema.value) || raise SQLError.new("unknown database #{schema.value}")
      end
      found = @session.table(statement.table.value)
      if found && found.database.same?(@session.temp_database)
        return found.database
      end
      @session.database
    end

    # The table or view the trigger fires on: for a TEMP trigger wherever
    # its name leads; otherwise in the trigger's own database.
    private def trigger_target(statement : SQL::CreateTrigger, database : Database, temporary : Bool) : {TableInfo?, ViewInfo?}
      name = statement.table.value
      if temporary
        schema = statement.table_schema.try(&.value)
        table = @session.table(name, schema)
        return {table, nil} if table
        return {nil, nil} if schema && @session.database_named(schema) != @session.database
        return {nil, @session.view(name)}
      end
      table = @session.table(name, @session.schema_name_of(database))
      return {table, nil} if table
      return {nil, nil} unless database.same?(@session.database)
      {nil, @session.view(name)}
    end

    private def drop_trigger(statement : SQL::Drop) : Nil
      name = statement.name.value
      schema = statement.schema
      found = @session.list_of_databases.compact_map do |candidate|
        next if schema && !candidate.same?(@session.database_named(schema.value))
        @session.trigger_named(name, candidate)
      end.first?
      unless found
        return if statement.if_exists
        raise SQLError.new("no such trigger: #{schema ? "#{schema.value}." : ""}#{name}")
      end
      trigger_name = found.trigger_name
      found.database.delete_schema_rows { |record| record[0]? == "trigger" && record[1]? == trigger_name }
      found.database.note_schema_change
    end

    # DROP TABLE also drops the TEMP triggers on the table.
    private def drop_temp_triggers_of(table_name : String) : Nil
      temp_database = @session.temp_database
      return if temp_database.nil?
      return if database.same?(temp_database) || temp_database.page_count == 0
      doomed = @session.list_of_triggers.select do |trigger|
        trigger.database.same?(temp_database) && trigger.table_name.compare(table_name, case_insensitive: true) == 0
      end
      return if doomed.empty?
      names = doomed.map(&.trigger_name)
      temp_database.delete_schema_rows { |record| record[0]? == "trigger" && names.includes?(record[1]?) }
      temp_database.note_schema_change
    end

    # sqlite3FixExpr refuses a bound parameter anywhere in a trigger.
    def self.uses_variables?(text : String) : Bool
      tokenizer = SQL::Tokenizer.new(text)
      loop do
        token = tokenizer.next_token
        return false if token.kind.end_of_input? || token.kind.illegal?
        return true if token.kind.variable?
      end
    end

    # The text sqlite_schema keeps after "CREATE TRIGGER ": from the
    # trigger's (unqualified) name through the END that closes its body.
    def self.trigger_text(text : String) : String
      tokenizer = SQL::Tokenizer.new(text)
      tokens = [] of SQL::Token
      loop do
        token = tokenizer.next_token
        break if token.kind.end_of_input? || token.kind.illegal?
        tokens << token
      end
      position = tokens.index(&.kind.trigger?) || 0
      position += 1
      # IF NOT EXISTS
      position += 3 if tokens[position]?.try(&.kind.if?)
      start = tokens[position]?.try(&.start) || 0
      if tokens[position + 1]?.try(&.kind.dot?)
        start = tokens[position + 2]?.try(&.start) || start
      end
      finish = text.bytesize
      tokens.each_with_index do |token, index|
        next unless token.kind.end? && index > 0 && tokens[index - 1].kind.semicolon?
        finish = token.start + token.size
      end
      text.byte_slice(start, finish - start)
    end
  end
end

module Grant::SQLiteEngine::Query
  # sqlite3FixTriggerStep: the schema names a trigger body's FROM items
  # and IN tables give, which a trigger outside TEMP may only point at its
  # own database.
  module TriggerSchemaNames
    def self.each_schema(statement : SQL::Statement, &block : String ->) : Nil
      case statement
      when SQL::Insert
        statement.source.try { |source| visit_select(source, &block) }
        statement.upserts.each do |upsert|
          upsert.target_where.try { |where| visit_expression(where, &block) }
          upsert.assignments.try &.each { |assignment| visit_expression(assignment.value, &block) }
          upsert.where.try { |where| visit_expression(where, &block) }
        end
      when SQL::Update
        statement.assignments.each { |assignment| visit_expression(assignment.value, &block) }
        statement.from.try { |from| visit_from(from, &block) }
        statement.where.try { |where| visit_expression(where, &block) }
      when SQL::Delete
        statement.where.try { |where| visit_expression(where, &block) }
      when SQL::SelectStatement
        visit_select(statement, &block)
      end
    end

    private def self.visit_select(statement : SQL::SelectStatement, &block : String ->) : Nil
      statement.with_clause.try &.tables.each { |table| visit_select(table.query, &block) }
      statement.cores.each do |core|
        case core
        when SQL::SelectClause
          core.columns.each do |column|
            visit_expression(column.expression, &block) if column.is_a?(SQL::ExpressionColumn)
          end
          core.from.try { |from| visit_from(from, &block) }
          core.where.try { |expression| visit_expression(expression, &block) }
          core.group_by.each { |expression| visit_expression(expression, &block) }
          core.having.try { |expression| visit_expression(expression, &block) }
        when SQL::ValuesClause
          core.rows.each(&.each { |expression| visit_expression(expression, &block) })
        end
      end
      statement.order_by.each { |term| visit_expression(term.expression, &block) }
    end

    private def self.visit_from(from : SQL::From, &block : String ->) : Nil
      from.items.each do |item|
        case source = item.source
        when SQL::TableReference
          source.schema.try { |schema| block.call(schema.value) }
        when SQL::TableFunction
          source.schema.try { |schema| block.call(schema.value) }
          source.arguments.each { |argument| visit_expression(argument, &block) }
        when SQL::SubquerySource then visit_select(source.query, &block)
        when SQL::NestedJoin     then visit_from(source.from, &block)
        end
        item.on.try { |expression| visit_expression(expression, &block) }
      end
    end

    private def self.visit_expression(expression : SQL::Expression, &block : String ->) : Nil
      case expression
      when SQL::Exists         then visit_select(expression.query, &block)
      when SQL::ScalarSubquery then visit_select(expression.query, &block)
      when SQL::InSelect
        visit_expression(expression.operand, &block)
        visit_select(expression.query, &block)
      when SQL::InTable
        visit_expression(expression.operand, &block)
        expression.schema.try { |schema| block.call(schema.value) }
      else
        ParameterScan::Walker.children(expression).each { |child| visit_expression(child, &block) }
      end
    end
  end
end
