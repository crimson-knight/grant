# The SQL front end (milestone G3): SQLite's tokenizer and grammar in
# Crystal, producing a typed syntax tree and printing it back as SQL.
# Specification: https://www.sqlite.org/lang.html and SQLite's parse.y.
module Grant::SQLiteEngine::SQL
end

require "./sql/token"
require "./sql/keywords"
require "./sql/limits"
require "./sql/parse_error"
require "./sql/tokenizer"
require "./sql/ast"
require "./sql/printer"
require "./sql/expression_parsing"
require "./sql/select_parsing"
require "./sql/table_parsing"
require "./sql/statement_parsing"
require "./sql/parser"
require "./sql/prepared_text"
require "./sql/savepoint_text"
