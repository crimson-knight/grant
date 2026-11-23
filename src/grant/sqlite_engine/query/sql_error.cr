module Grant::SQLiteEngine
  # An error SQLite reports while preparing or running a statement, with
  # its result code (https://www.sqlite.org/rescode.html) and C SQLite's
  # message text (`no such table: users`, `datatype mismatch`).
  class SQLError < Error
    ERROR      =  1
    INTERRUPT  =  9
    TOO_BIG    = 18
    CONSTRAINT = 19
    MISMATCH   = 20
    RANGE      = 25

    getter result_code : Int32

    def initialize(message : String, @result_code : Int32 = ERROR)
      super(message)
    end
  end

  # The last name error of one resolved expression: it ends the walk of
  # the enclosing expression too (a subquery's resolve aborts its parent's).
  class ResolveError < SQLError
  end
end
