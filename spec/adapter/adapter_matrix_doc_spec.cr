require "../spec_helper"

# Keeps the capability table in docs/adapter_matrix.md equal to what the
# predicates answer. Refresh the file with GRANT_WRITE_ADAPTER_MATRIX=1.
private MATRIX_PATH  = File.join(__DIR__, "../../docs/adapter_matrix.md")
private START_MARKER = "<!-- capabilities:start -->"
private END_MARKER   = "<!-- capabilities:end -->"

private def yes_no(value : Bool) : String
  value ? "yes" : "no"
end

private def generated_matrix : String
  pg = Grant::Adapter::Pg.new(name: "g01_doc_pg", url: "postgres://localhost/unused")
  pg.database_version = Grant::ServerVersion.new(17)
  mysql = Grant::Adapter::Mysql.new(name: "g01_doc_mysql", url: "mysql://localhost/unused")
  mysql.database_version = Grant::ServerVersion.new(8, 0, 35)
  mysql.mariadb = false
  sqlite = Grant::Adapter::Sqlite.new(name: "g01_doc_sqlite", url: "sqlite3:/tmp/g01_doc.db")
  sqlite.database_version = Grant::ServerVersion.new(3, 45)

  gates = {
    "supports_insert_returning?"         => "SQLite 3.35; MariaDB 10.5",
    "supports_expression_index?"         => "MySQL 8.0.13",
    "supports_check_constraints?"        => "MySQL 8.0.16; MariaDB 10.2.1",
    "supports_datetime_with_precision?"  => "MySQL 5.6.4; MariaDB 5.3",
    "supports_json?"                     => "MySQL 5.7.8; MariaDB 10.2.7; SQLite 3.38",
    "supports_common_table_expressions?" => "MySQL 8.0.1; MariaDB 10.2.1",
    "supports_virtual_columns?"          => "PostgreSQL 12; MySQL 5.7.6; MariaDB 10.2; SQLite 3.31",
    "supports_optimizer_hints?"          => "MySQL 5.7.7",
    "supports_concurrent_connections?"   => "SQLite: file databases only",
    "supports_nulls_not_distinct?"       => "PostgreSQL 15",
  }

  rows = {% begin %}
    [
      {% for name in %w[
                       supports_insert_returning? supports_insert_on_duplicate_skip? supports_insert_on_duplicate_update?
                       supports_ddl_transactions? supports_partial_index? supports_expression_index?
                       supports_check_constraints? supports_foreign_keys? supports_views?
                       supports_datetime_with_precision? supports_json? supports_common_table_expressions?
                       supports_virtual_columns? supports_comments? supports_explain? supports_optimizer_hints?
                       supports_advisory_locks? supports_bulk_alter? supports_concurrent_connections?
                       supports_restart_db_transaction? supports_disable_referential_integrity?
                       supports_nulls_not_distinct?
                     ] %}
        { {{ name }}, pg.{{ name.id }}, mysql.{{ name.id }}, sqlite.{{ name.id }} },
      {% end %}
    ]
  {% end %}

  String.build do |io|
    io << "| Predicate | PostgreSQL 17 | MySQL 8.0.35 | SQLite 3.45 | Version gates |\n"
    io << "| --- | --- | --- | --- | --- |\n"
    rows.each do |(name, pg_value, mysql_value, sqlite_value)|
      io << "| `" << name << "` | " << yes_no(pg_value) << " | " << yes_no(mysql_value) << " | " << yes_no(sqlite_value)
      io << " | " << (gates[name]? || "") << " |\n"
    end
  end
end

describe "docs/adapter_matrix.md" do
  it "lists exactly what the capability predicates answer" do
    document = File.read(MATRIX_PATH)
    start_index = document.index!(START_MARKER)
    end_index = document.index!(END_MARKER)
    table = generated_matrix

    if ENV["GRANT_WRITE_ADAPTER_MATRIX"]?
      updated = document[0, start_index + START_MARKER.size] + "\n" + table + document[end_index..]
      File.write(MATRIX_PATH, updated)
    else
      current = document[(start_index + START_MARKER.size)...end_index].strip
      current.should eq(table.strip)
    end
  end
end
