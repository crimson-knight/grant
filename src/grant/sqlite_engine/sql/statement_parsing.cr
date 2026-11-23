module Grant::SQLiteEngine::SQL
  # Every statement other than SELECT and CREATE TABLE (parse.y `cmd`).
  module StatementParsing
    private def parse_statement : Statement
      if accept(TokenKind::Explain)
        query_plan = false
        if accept(TokenKind::Query)
          expect(TokenKind::Plan)
          query_plan = true
        end
        return Explain.new(query_plan, parse_command)
      end
      parse_command
    end

    private def parse_command : Statement
      case kind
      when .begin?         then parse_begin
      when .commit?, .end? then parse_commit
      when .rollback?      then parse_rollback
      when .savepoint?     then advance; Savepoint.new(parse_nm)
      when .release?
        advance
        savepoint_keyword = accept(TokenKind::Savepoint)
        Release.new(savepoint_keyword, parse_nm)
      when .create?           then parse_create
      when .drop?             then parse_drop
      when .select?, .values? then parse_select
      when .with?
        with_clause = parse_with_clause
        case kind
        when .select?, .values?  then parse_select(with_clause)
        when .delete?            then parse_delete(with_clause, trigger: false)
        when .update?            then parse_update(with_clause, trigger: false)
        when .insert?, .replace? then parse_insert(with_clause, trigger: false)
        else                          syntax_error
        end
      when .delete?            then parse_delete(nil, trigger: false)
      when .update?            then parse_update(nil, trigger: false)
      when .insert?, .replace? then parse_insert(nil, trigger: false)
      when .vacuum?            then parse_vacuum
      when .pragma?            then parse_pragma
      when .attach?            then parse_attach
      when .detach?
        advance
        database_keyword = accept(TokenKind::Database)
        Detach.new(database_keyword, parse_expression)
      when .reindex?
        advance
        schema, name = nm? ? parse_qualified_name : {nil, nil}
        Reindex.new(schema, name)
      when .analyze?
        advance
        schema, name = nm? ? parse_qualified_name : {nil, nil}
        Analyze.new(schema, name)
      when .alter? then parse_alter
      else              syntax_error
      end
    end

    # --------------------------------------------------------- transactions

    private def parse_transaction_name : {Bool, Name?}
      return {false, nil} unless accept(TokenKind::Transaction)
      {true, nm? ? parse_nm : nil}
    end

    private def parse_begin : Statement
      expect(TokenKind::Begin)
      mode = case kind
             when .deferred?  then advance; TransactionMode::Deferred
             when .immediate? then advance; TransactionMode::Immediate
             when .exclusive? then advance; TransactionMode::Exclusive
             else                  TransactionMode::None
             end
      keyword, name = parse_transaction_name
      Begin.new(mode, keyword, name)
    end

    private def parse_commit : Statement
      word = text(advance).upcase
      keyword, name = parse_transaction_name
      Commit.new(word, keyword, name)
    end

    private def parse_rollback : Statement
      expect(TokenKind::Rollback)
      keyword, name = parse_transaction_name
      savepoint = nil
      savepoint_keyword = false
      if accept(TokenKind::To)
        savepoint_keyword = accept(TokenKind::Savepoint)
        savepoint = parse_nm
      end
      Rollback.new(keyword, name, savepoint, savepoint_keyword)
    end

    # ------------------------------------------------------------------ DDL

    private def parse_create : Statement
      expect(TokenKind::Create)
      temporary = kind.temp? ? name_of(advance) : nil
      case kind
      when .table?   then parse_create_table(temporary)
      when .view?    then parse_create_view(temporary)
      when .trigger? then parse_create_trigger(temporary)
      when .unique?, .index?
        syntax_error if temporary
        parse_create_index
      when .virtual?
        syntax_error if temporary
        parse_create_virtual_table
      else
        syntax_error
      end
    end

    private def parse_create_index : Statement
      unique = accept(TokenKind::Unique)
      expect(TokenKind::Index)
      if_not_exists = parse_if_not_exists
      schema, name = parse_qualified_name
      check_object_name(name)
      expect(TokenKind::On)
      table = parse_nm
      expect(TokenKind::LeftParen)
      columns = parse_ordering_terms
      expect(TokenKind::RightParen)
      where = accept(TokenKind::Where) ? parse_expression : nil
      CreateIndex.new(unique, if_not_exists, schema, name, table, columns, where)
    end

    private def parse_create_view(temporary : Name?) : Statement
      expect(TokenKind::View)
      if_not_exists = parse_if_not_exists
      schema, name = parse_qualified_name
      check_object_name(name)
      columns = kind.left_paren? ? parse_eidlist : nil
      expect(TokenKind::As)
      CreateView.new(temporary, if_not_exists, schema, name, columns, parse_select)
    end

    private def parse_create_trigger(temporary : Name?) : Statement
      expect(TokenKind::Trigger)
      if_not_exists = parse_if_not_exists
      schema, name = parse_qualified_name
      time = case kind
             when .before? then advance; TriggerTime::Before
             when .after?  then advance; TriggerTime::After
             when .instead?
               advance
               expect(TokenKind::Of)
               TriggerTime::InsteadOf
             else
               TriggerTime::None
             end
      update_columns = nil
      event = case kind
              when .delete? then advance; TriggerEvent::Delete
              when .insert? then advance; TriggerEvent::Insert
              when .update?
                advance
                if accept(TokenKind::Of)
                  update_columns = [parse_nm]
                  while accept(TokenKind::Comma)
                    update_columns << parse_nm
                  end
                end
                TriggerEvent::Update
              else
                syntax_error
              end
      expect(TokenKind::On)
      table_schema, table = parse_qualified_name
      for_each_row = false
      if accept(TokenKind::For)
        expect(TokenKind::Each)
        expect(TokenKind::Row)
        for_each_row = true
      end
      when_condition = accept(TokenKind::When) ? parse_expression : nil
      if temporary && schema
        action_error("temporary trigger may not have qualified name")
      end
      check_object_name(name)
      expect(TokenKind::Begin)
      body = [] of Statement
      loop do
        @in_trigger = true
        body << parse_trigger_command
        @in_trigger = false
        expect(TokenKind::Semicolon)
        break if kind.end?
      end
      expect(TokenKind::End)
      CreateTrigger.new(temporary, if_not_exists, schema, name, time, event, update_columns, table_schema, table,
        for_each_row, when_condition, body)
    end

    private def parse_trigger_command : Statement
      case kind
      when .update?            then parse_update(nil, trigger: true)
      when .insert?, .replace? then parse_insert(nil, trigger: true)
      when .delete?            then parse_delete(nil, trigger: true)
      when .select?, .values?, .with?
        parse_select
      else
        syntax_error
      end
    end

    private def parse_create_virtual_table : Statement
      expect(TokenKind::Virtual)
      expect(TokenKind::Table)
      if_not_exists = parse_if_not_exists
      schema, name = parse_qualified_name
      check_object_name(name)
      expect(TokenKind::Using)
      module_name = parse_nm
      arguments = nil
      if accept(TokenKind::LeftParen)
        arguments = parse_module_arguments
      end
      CreateVirtualTable.new(if_not_exists, schema, name, module_name, arguments)
    end

    # parse.y's vtabarglist: any tokens, split at commas outside nested
    # parentheses, each argument kept as its source text.
    private def parse_module_arguments : Array(String)
      arguments = [] of String
      depth = 0
      first_token = nil
      last_token = nil
      loop do
        token = peek
        syntax_error(token) if token.kind.end_of_input?
        if depth == 0 && (token.kind.comma? || token.kind.right_paren?)
          arguments << source_between(first_token, last_token)
          first_token = nil
          last_token = nil
          advance
          break if token.kind.right_paren?
          next
        end
        depth += 1 if token.kind.left_paren?
        depth -= 1 if token.kind.right_paren?
        first_token ||= token
        last_token = token
        advance
      end
      arguments
    end

    private def source_between(first : Token?, last : Token?) : String
      return "" unless first && last
      @tokenizer.source.byte_slice(first.start, last.end_offset - first.start)
    end

    private def parse_drop : Statement
      expect(TokenKind::Drop)
      drop_kind = case kind
                  when .table?   then DropKind::Table
                  when .view?    then DropKind::View
                  when .index?   then DropKind::Index
                  when .trigger? then DropKind::Trigger
                  else                syntax_error
                  end
      advance
      if_exists = false
      if accept(TokenKind::If)
        expect(TokenKind::Exists)
        if_exists = true
      end
      schema, name = parse_qualified_name
      Drop.new(drop_kind, if_exists, schema, name)
    end

    private def parse_alter : Statement
      expect(TokenKind::Alter)
      expect(TokenKind::Table)
      schema, table = parse_qualified_name
      action = case kind
               when .rename?
                 advance
                 if accept(TokenKind::To)
                   new_name = parse_nm
                   check_object_name(new_name)
                   RenameTable.new(new_name)
                 else
                   column_keyword = accept(TokenKind::Column)
                   old_name = parse_nm
                   expect(TokenKind::To)
                   RenameColumn.new(column_keyword, old_name, parse_nm)
                 end
               when .add?
                 advance
                 column_keyword = accept(TokenKind::Column)
                 AddColumn.new(column_keyword, parse_column_definition(TableParsing::TableUnderConstruction.new(table.value)))
               when .drop?
                 advance
                 column_keyword = accept(TokenKind::Column)
                 DropColumn.new(column_keyword, parse_nm)
               else
                 syntax_error
               end
      AlterTable.new(schema, table, action)
    end

    # ------------------------------------------------------------- the rest

    private def parse_vacuum : Statement
      expect(TokenKind::Vacuum)
      schema = nm? ? parse_nm : nil
      into = accept(TokenKind::Into) ? parse_expression : nil
      Vacuum.new(schema, into)
    end

    private def parse_pragma : Statement
      expect(TokenKind::Pragma)
      schema, name = parse_qualified_name
      if accept(TokenKind::Equal)
        return Pragma.new(schema, name, PragmaForm::Assignment, parse_pragma_value)
      end
      if accept(TokenKind::LeftParen)
        value = parse_pragma_value
        expect(TokenKind::RightParen)
        return Pragma.new(schema, name, PragmaForm::Call, value)
      end
      Pragma.new(schema, name, PragmaForm::Bare, nil)
    end

    # parse.y's nmnum or minus_num.
    private def parse_pragma_value : String
      case kind
      when .plus?, .minus?, .integer?, .float?
        parse_signed_number
      when .on?, .delete?, .default?
        text(advance)
      else
        parse_nm.text
      end
    end

    private def parse_attach : Statement
      expect(TokenKind::Attach)
      database_keyword = accept(TokenKind::Database)
      file = parse_expression
      expect(TokenKind::As)
      schema = parse_expression
      key = accept(TokenKind::Key) ? parse_expression : nil
      Attach.new(database_keyword, file, schema, key)
    end

    # ------------------------------------------------------------------ DML

    # The target of INSERT, UPDATE or DELETE. Inside a trigger body the
    # name may not be qualified and takes no alias (parse.y trnm).
    private def parse_dml_target(trigger : Bool) : QualifiedTable
      schema, name = parse_qualified_name
      if trigger
        if schema
          action_error("qualified table names are not allowed on INSERT, UPDATE, and DELETE statements within triggers")
        end
        return QualifiedTable.new(nil, name, nil)
      end
      alias_name = accept(TokenKind::As) ? parse_nm : nil
      QualifiedTable.new(schema, name, alias_name)
    end

    private def parse_dml_indexed_by(trigger : Bool) : {Name?, Bool}
      indexed_by, not_indexed = parse_indexed_by
      if trigger && indexed_by
        action_error("the INDEXED BY clause is not allowed on UPDATE or DELETE statements within triggers")
      end
      if trigger && not_indexed
        action_error("the NOT INDEXED clause is not allowed on UPDATE or DELETE statements within triggers")
      end
      {indexed_by, not_indexed}
    end

    private def parse_returning : Array(ResultColumn)?
      return nil unless accept(TokenKind::Returning)
      columns, _ = parse_result_columns
      columns
    end

    private def parse_delete(with_clause : WithClause?, trigger : Bool) : Statement
      expect(TokenKind::Delete)
      expect(TokenKind::From)
      table = parse_dml_target(trigger)
      indexed_by, not_indexed = parse_dml_indexed_by(trigger)
      where = accept(TokenKind::Where) ? parse_expression : nil
      returning = trigger ? nil : parse_returning
      Delete.new(with_clause, table, indexed_by, not_indexed, where, returning)
    end

    private def parse_update(with_clause : WithClause?, trigger : Bool) : Statement
      expect(TokenKind::Update)
      conflict = parse_or_conflict
      table = parse_dml_target(trigger)
      indexed_by, not_indexed = parse_dml_indexed_by(trigger)
      expect(TokenKind::Set)
      assignments = parse_assignments
      from = accept(TokenKind::From) ? parse_from : nil
      where = accept(TokenKind::Where) ? parse_expression : nil
      returning = trigger ? nil : parse_returning
      Update.new(with_clause, conflict, table, indexed_by, not_indexed, assignments, from, where, returning)
    end

    # parse.y's setlist: `name = value` or `(a, b) = value`, comma separated.
    private def parse_assignments : Array(Assignment)
      assignments = [] of Assignment
      loop do
        if kind.left_paren?
          columns = parse_name_list
          expect(TokenKind::Equal)
          assignments << Assignment.new(columns, true, parse_expression)
        else
          column = parse_nm
          expect(TokenKind::Equal)
          assignments << Assignment.new([column], false, parse_expression)
        end
        break unless accept(TokenKind::Comma)
      end
      assignments
    end

    private def parse_insert(with_clause : WithClause?, trigger : Bool) : Statement
      verb = InsertVerb::Insert
      conflict = nil
      if accept(TokenKind::Replace)
        verb = InsertVerb::Replace
      else
        expect(TokenKind::Insert)
        conflict = parse_or_conflict
      end
      expect(TokenKind::Into)
      table = parse_dml_target(trigger)
      columns = kind.left_paren? ? parse_name_list : nil
      if !trigger && accept(TokenKind::Default)
        expect(TokenKind::Values)
        return Insert.new(with_clause, verb, conflict, table, columns, nil, [] of Upsert, parse_returning)
      end
      syntax_error unless select_start?
      source = parse_select
      upserts, returning = parse_upserts
      action_error("cannot use RETURNING in a trigger") if trigger && returning
      Insert.new(with_clause, verb, conflict, table, columns, source, upserts, returning)
    end

    # parse.y's upsert: any number of `ON CONFLICT (target) ...` clauses,
    # then optionally a target-less one, then RETURNING.
    private def parse_upserts : {Array(Upsert), Array(ResultColumn)?}
      upserts = [] of Upsert
      loop do
        if kind.returning?
          return {upserts, parse_returning}
        end
        return {upserts, nil} unless kind.on?
        advance
        expect(TokenKind::Conflict)
        if accept(TokenKind::LeftParen)
          target = parse_ordering_terms
          expect(TokenKind::RightParen)
          target_where = accept(TokenKind::Where) ? parse_expression : nil
          upserts << parse_upsert_action(target, target_where)
        else
          upserts << parse_upsert_action(nil, nil)
          return {upserts, parse_returning}
        end
      end
    end

    private def parse_upsert_action(target : Array(OrderingTerm)?, target_where : Expression?) : Upsert
      expect(TokenKind::Do)
      if accept(TokenKind::Nothing)
        return Upsert.new(target, target_where, nil, nil)
      end
      expect(TokenKind::Update)
      expect(TokenKind::Set)
      assignments = parse_assignments
      where = accept(TokenKind::Where) ? parse_expression : nil
      Upsert.new(target, target_where, assignments, where)
    end
  end
end
