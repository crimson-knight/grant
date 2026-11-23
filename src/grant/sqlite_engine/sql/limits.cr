module Grant::SQLiteEngine::SQL
  # Bounds the parser enforces. Each cites https://www.sqlite.org/limits.html
  # or the part of SQLite that sets it.
  module Limits
    # SQLITE_MAX_SQL_LENGTH is 1,000,000,000 bytes; the engine takes the
    # plan's 1 MiB-class bound of 1,000,000 bytes, which every statement
    # Grant issues stays far below.
    MAX_SQL_LENGTH = 1_000_000

    # SQLITE_MAX_EXPR_DEPTH: the tallest expression tree.
    MAX_EXPRESSION_DEPTH = 1_000

    # How deeply the parser recurses (nested parentheses, subqueries,
    # prefix operators) before it stops, so input cannot exhaust the stack.
    # C SQLite's parser stack grows on the heap instead, so text nested
    # deeper than this without growing the expression tree (parentheses
    # alone) is accepted by C SQLite and rejected here.
    MAX_PARSER_NESTING = 1_000

    # SQLITE_MAX_COMPOUND_SELECT: terms in a compound SELECT.
    MAX_COMPOUND_SELECT = 500

    # SQLITE_MAX_VARIABLE_NUMBER: the largest parameter number.
    MAX_VARIABLE_NUMBER = 32_766

    # SQLITE_MAX_FUNCTION_ARG: arguments to one function call.
    MAX_FUNCTION_ARGUMENTS = 1_000

    # SQLITE_MAX_COLUMN: columns in a table.
    MAX_COLUMNS = SQLiteEngine::Limits::MAX_COLUMNS
  end
end
