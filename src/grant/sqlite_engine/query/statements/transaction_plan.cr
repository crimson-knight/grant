module Grant::SQLiteEngine::Query
  # BEGIN, COMMIT/END, ROLLBACK [TO], SAVEPOINT and RELEASE
  # (lang_transaction.html, lang_savepoint.html).
  class TransactionPlan < StatementPlan
    def initialize(@session : Session, @statement : SQL::Statement)
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      statement = @statement
      case statement
      when SQL::Begin
        @session.begin_transaction(immediate: statement.mode.immediate? || statement.mode.exclusive?, exclusive: statement.mode.exclusive?)
      when SQL::Commit
        @session.commit_transaction
      when SQL::Rollback
        if savepoint = statement.savepoint
          @session.rollback_to(savepoint.value)
        else
          @session.rollback_transaction
        end
      when SQL::Savepoint
        @session.savepoint(statement.name.value)
      when SQL::Release
        @session.release(statement.name.value)
      end
      NO_ROWS
    end
  end
end

module Grant::SQLiteEngine::Query
  # SAVEPOINT or RELEASE of the name a statement's frame holds: one plan
  # serves every statement of that shape (see `SQL::SavepointText`).
  class NamedSavepointPlan < TransactionPlan
    def initialize(session : Session, statement : SQL::Statement, @release : Bool)
      super(session, statement)
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      name = list_of_parameters[0]?
      raise Error.new("a savepoint statement ran without its name") unless name.is_a?(String)
      @release ? @session.release(name) : @session.savepoint(name)
      NO_ROWS
    end
  end
end
