module Grant::SQLiteEngine::Query
  class Session
    # Counts schema resets; a compiled write statement older than this is
    # compiled again before it runs.
    getter schema_epoch = 0

    def reset_schema : Nil
      previous_def
      @schema_epoch += 1
    end
  end

  # Compiles a statement other than SELECT to its plan.
  module StatementCompiler
    def self.compile(session : Session, statement : SQL::Statement, text : String) : StatementPlan
      plan = case statement
             when SQL::Insert then InsertPlan.new(session, statement)
             when SQL::Update then UpdatePlan.new(session, statement)
             when SQL::Delete then DeletePlan.new(session, statement)
             when SQL::Begin, SQL::Commit, SQL::Rollback, SQL::Savepoint, SQL::Release
               TransactionPlan.new(session, statement)
             when SQL::Pragma then PragmaPlan.new(session, statement)
             when SQL::CreateTable, SQL::CreateIndex, SQL::CreateView, SQL::Drop, SQL::AlterTable,
                  SQL::CreateTrigger, SQL::CreateVirtualTable
               SchemaPlan.new(session, statement, text)
             when SQL::Explain    then ExplainPlan.new(session, statement)
             when SQL::Analyze    then NoRowsPlan.new
             when SQL::Reindex    then NoRowsPlan.new
             when SQL::Vacuum     then NoRowsPlan.new
             when SQL::Attach     then raise UnsupportedSQL.new("ATTACH (the engine opens one database per connection)")
             when SQL::Detach     then raise UnsupportedSQL.new("DETACH")
             else
               raise UnsupportedSQL.new("#{PreparedQuery.statement_kind(statement)} statements")
             end
      plan.schema_generation = session.schema_epoch
      plan
    end
  end

  # A statement that does nothing on this engine and returns no rows
  # (ANALYZE, REINDEX and VACUUM leave a correct database as it is).
  class NoRowsPlan < StatementPlan
    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      [] of Array(Value)
    end
  end

  # EXPLAIN QUERY PLAN: C's four columns with one row per FROM table (Grant
  # only displays the text); plain EXPLAIN (bytecode) has no equivalent.
  class ExplainPlan < StatementPlan
    def initialize(@session : Session, @statement : SQL::Explain)
      raise UnsupportedSQL.new("EXPLAIN without QUERY PLAN (VDBE bytecode)") unless @statement.query_plan
      @list_of_column_names = %w[id parent notused detail]
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      inner = @statement.statement
      names = [] of String
      if inner.is_a?(SQL::SelectStatement)
        inner.cores.each do |core|
          next unless core.is_a?(SQL::SelectClause)
          core.from.try(&.items.each do |item|
            source = item.source
            names << source.name.value if source.is_a?(SQL::TableReference)
          end)
        end
      end
      names = ["CONSTANT ROW"] if names.empty?
      names.map_with_index do |name, index|
        [(index + 2).to_i64, 0_i64, 0_i64, name == "CONSTANT ROW" ? "SCAN CONSTANT ROW" : "SCAN #{name}"] of Value
      end
    end
  end

  # Runs a statement plan when its query is first stepped and hands out
  # the rows it returned.
  class PlanProducer < Producer
    @rows = [] of Array(Value)
    @position = 0

    def initialize(@session : Session, @plan : StatementPlan, @statement : SQL::Statement, @text : String)
    end

    def open(frame : Frame) : Nil
      if @plan.schema_generation != @session.schema_epoch && !@plan.is_a?(TransactionPlan)
        @plan = StatementCompiler.compile(@session, @statement, @text)
      end
      @position = 0
      @rows = begin
        @plan.run(frame.list_of_parameters)
      rescue error : SQLError | UnsupportedSQL
        raise error
      rescue error : ConstraintViolation
        raise ConstraintError.new(error.message || "constraint failed")
      rescue error : Busy
        raise SQLError.new("database is locked", 5)
      rescue error : CorruptDatabase
        raise SQLError.new(error.message || "database disk image is malformed", 11)
      rescue error : ReadOnlyDatabase
        raise SQLError.new("attempt to write a readonly database", 8)
      rescue error : Error
        raise SQLError.new(error.message || "SQL logic error")
      end
    end

    def next_row(frame : Frame) : Array(Value)?
      row = @rows[@position]?
      @position += 1 if row
      row
    end

    def list_of_column_names : Array(String)
      @plan.list_of_column_names
    end
  end
end
