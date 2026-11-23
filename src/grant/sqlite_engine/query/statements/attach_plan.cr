module Grant::SQLiteEngine::Query
  # ATTACH and DETACH (attachFunc, detachFunc). A bare name in either
  # position is its own text, as resolveAttachExpr turns TK_ID into a
  # string; any other expression is evaluated, parameters included.
  class AttachPlan < StatementPlan
    @attach : SQL::Attach? = nil
    @detach : SQL::Detach? = nil

    def initialize(@session : Session, statement : SQL::Statement)
      @attach = statement.as?(SQL::Attach)
      @detach = statement.as?(SQL::Detach)
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      if attach = @attach
        file = text_of(attach.file, list_of_parameters) || ""
        name = text_of(attach.schema, list_of_parameters) || ""
        @session.attach(file, name)
      elsif detach = @detach
        @session.detach(text_of(detach.schema, list_of_parameters) || "")
      end
      [] of Array(Value)
    end

    private def text_of(expression : SQL::Expression, list_of_parameters : Array(Value)) : String?
      if expression.is_a?(SQL::ColumnReference) && expression.table.nil? && expression.schema.nil?
        return expression.column.value
      end
      program = RowProgram.new(@session, RowProgram.columns([expression]), [] of PseudoTable)
      row = program.evaluate(list_of_parameters)
      row ? ValueSemantics.text(row[0]) : nil
    end
  end
end
