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
        @session.begin_transaction
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
      [] of Array(Value)
    end
  end
end
