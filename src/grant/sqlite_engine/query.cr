# Query execution (milestone G4): SELECT statements compiled from the G3
# syntax tree into a tree-walking plan of row sources, producers and
# expressions over G1's b-tree reader, with SQLite 3.51.0's name
# resolution, affinity, collation and NULL rules.
# Specification: https://www.sqlite.org/lang_select.html ,
# https://www.sqlite.org/datatype3.html , https://www.sqlite.org/lang_expr.html
module Grant::SQLiteEngine::Query
end

require "./query/sql_error"
require "./query/numeric_text"
require "./query/collation"
require "./query/value_semantics"
require "./query/pattern_match"
require "./query/table_info"
require "./query/expressions"
require "./query/scalar_functions"
require "./query/aggregate_functions"
require "./query/btree_cursor"
require "./query/row_sources"
require "./query/producers"
require "./query/subquery_expressions"
require "./query/expression_children"
require "./query/expression_data_type"
require "./query/condition_logic"
require "./query/catalog"
require "./query/name_scope"
require "./query/expression_compiler"
require "./query/compiler"
require "./query/from_compiler"
require "./query/access_planner"
require "./query/session"
require "./query/prepared_query"
require "./query/statements/row_program"
require "./query/statements/write_table"
require "./query/statements/statement_plan"
require "./query/statements/write_run"
require "./query/statements/session_writes"
require "./query/statements/insert_plan"
require "./query/statements/update_plan"
require "./query/statements/transaction_plan"
require "./query/statements/pragma_plan"
require "./query/statements/schema_plan"
require "./query/statements/schema_alteration"
require "./query/statements/statement_compiler"
require "./query/statements/backup"
