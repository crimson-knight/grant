# The SQL type the database catalog reports for *column* of *table*,
# lowercased (`jsonb` on PostgreSQL, `json` on MySQL, `text` on SQLite for a
# `JSON::Any` column). Raises when the table has no such column.
def database_column_type(adapter : Grant::Adapter::Base, table : String, column : String) : String
  column_info = adapter.catalog_columns(table).find { |candidate| candidate.name == column }
  raise "#{table} has no column #{column}" unless column_info
  column_info.sql_type.downcase
end
