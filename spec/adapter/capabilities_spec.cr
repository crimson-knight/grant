require "../spec_helper"

alias G01Version = Grant::ServerVersion

class G01BareAdapter < Grant::Adapter::Base
  QUOTING_CHAR = '"'

  def clear(table_name : String)
  end

  def insert(table_name : String, fields, params, lastval) : Int64
    0_i64
  end

  def import(table_name : String, primary_name : String, auto : Bool, fields, model_array, **options)
  end

  def update(table_name : String, primary_name : String, fields, params)
  end

  def delete(table_name : String, primary_name : String, value)
  end

  def supports_lock_mode?(mode : Grant::Locking::LockMode) : Bool
    false
  end

  def supports_isolation_level?(level : Grant::Transaction::IsolationLevel) : Bool
    false
  end

  def supports_savepoints? : Bool
    false
  end
end

# Counts how often the server would be asked for its version.
class G01CountingAdapter < G01BareAdapter
  QUOTING_CHAR = '"'

  getter fetches = 0

  def supports_json? : Bool
    database_version.at_least?(5)
  end

  protected def fetch_database_version : Grant::ServerVersion
    @fetches += 1
    Grant::ServerVersion.new(8)
  end
end

# Every predicate, in the order docs/adapter_matrix.md lists them.
G01_PREDICATES = %w(
  supports_insert_returning? supports_insert_on_duplicate_skip? supports_insert_on_duplicate_update?
  supports_ddl_transactions? supports_partial_index? supports_expression_index?
  supports_check_constraints? supports_foreign_keys? supports_views?
  supports_datetime_with_precision? supports_json? supports_common_table_expressions?
  supports_virtual_columns? supports_comments? supports_explain? supports_optimizer_hints?
  supports_advisory_locks? supports_bulk_alter? supports_concurrent_connections?
  supports_restart_db_transaction? supports_disable_referential_integrity?
  supports_nulls_not_distinct?
)

# Answers for each adapter at the versions the specs pin.
private def capability_answers(adapter : Grant::Adapter::Base) : Hash(String, Bool)
  {% begin %}
    {
      {% for name in %w(
                       supports_insert_returning? supports_insert_on_duplicate_skip? supports_insert_on_duplicate_update?
                       supports_ddl_transactions? supports_partial_index? supports_expression_index?
                       supports_check_constraints? supports_foreign_keys? supports_views?
                       supports_datetime_with_precision? supports_json? supports_common_table_expressions?
                       supports_virtual_columns? supports_comments? supports_explain? supports_optimizer_hints?
                       supports_advisory_locks? supports_bulk_alter? supports_concurrent_connections?
                       supports_restart_db_transaction? supports_disable_referential_integrity?
                       supports_nulls_not_distinct?
                     ) %}
        {{ name }} => adapter.{{ name.id }},
      {% end %}
    }
  {% end %}
end

private def pg_at(major : Int32, minor : Int32 = 0)
  adapter = Grant::Adapter::Pg.new(name: "g01_cap_pg", url: "postgres://localhost/unused")
  adapter.database_version = G01Version.new(major, minor)
  adapter
end

private def mysql_at(major : Int32, minor : Int32, patch : Int32, mariadb : Bool = false)
  adapter = Grant::Adapter::Mysql.new(name: "g01_cap_mysql", url: "mysql://localhost/unused")
  adapter.database_version = G01Version.new(major, minor, patch)
  adapter.mariadb = mariadb
  adapter
end

private def sqlite_at(major : Int32, minor : Int32, patch : Int32 = 0, url : String = "sqlite3:/tmp/g01_cap.db")
  adapter = Grant::Adapter::Sqlite.new(name: "g01_cap_sqlite", url: url)
  adapter.database_version = G01Version.new(major, minor, patch)
  adapter
end

describe "Grant adapter capability predicates" do
  describe Grant::ServerVersion do
    it "parses server banners" do
      G01Version.parse("8.0.35").to_s.should eq("8.0.35")
      G01Version.parse("10.6.12-MariaDB-log").to_s.should eq("10.6.12")
      G01Version.parse("3.45").to_s.should eq("3.45.0")
      G01Version.parse("17").to_s.should eq("17.0.0")
    end

    it "rejects a banner without a number" do
      expect_raises(ArgumentError) { G01Version.parse("unknown") }
    end

    it "compares numerically" do
      (G01Version.new(9, 6) < G01Version.new(10, 0)).should be_true
      (G01Version.new(10, 10) > G01Version.new(10, 9)).should be_true
      G01Version.new(8, 0, 16).at_least?(8, 0, 16).should be_true
      G01Version.new(8, 0, 15).at_least?(8, 0, 16).should be_false
    end
  end

  describe "the base adapter" do
    it "answers false for every predicate an adapter does not override" do
      bare = G01BareAdapter.new("g01_bare", "bare://unused")
      capability_answers(bare).values.uniq.should eq([false])
      bare.adapter_name.should eq("G01BareAdapter")
    end

    it "fails clearly when an adapter cannot report identity" do
      bare = G01BareAdapter.new("g01_bare", "bare://unused")
      expect_raises(Grant::ErrorBase, /current_database/) { bare.current_database }
      expect_raises(Grant::ErrorBase, /fetch_database_version/) { bare.database_version }
    end
  end

  describe "PostgreSQL" do
    it "answers each predicate" do
      answers = capability_answers(pg_at(17))
      answers.select { |_, value| value }.keys.sort!.should eq(%w(
        supports_advisory_locks? supports_bulk_alter? supports_check_constraints?
        supports_common_table_expressions? supports_comments? supports_concurrent_connections?
        supports_datetime_with_precision? supports_ddl_transactions? supports_disable_referential_integrity?
        supports_explain? supports_expression_index? supports_foreign_keys? supports_insert_on_duplicate_skip?
        supports_insert_on_duplicate_update? supports_insert_returning? supports_json?
        supports_nulls_not_distinct? supports_partial_index? supports_restart_db_transaction?
        supports_views? supports_virtual_columns?
      ).sort!)
      answers["supports_optimizer_hints?"].should be_false
    end

    it "gates virtual columns on PostgreSQL 12" do
      pg_at(11, 9).supports_virtual_columns?.should be_false
      pg_at(12).supports_virtual_columns?.should be_true
    end

    it "gates NULLS NOT DISTINCT on PostgreSQL 15" do
      pg_at(14, 9).supports_nulls_not_distinct?.should be_false
      pg_at(15).supports_nulls_not_distinct?.should be_true
    end

    it "names itself" do
      pg_at(17).adapter_name.should eq("PostgreSQL")
    end
  end

  describe "MySQL" do
    it "answers each predicate on MySQL 8.0.35" do
      answers = capability_answers(mysql_at(8, 0, 35))
      answers.select { |_, value| value }.keys.sort!.should eq(%w(
        supports_advisory_locks? supports_bulk_alter? supports_check_constraints?
        supports_common_table_expressions? supports_comments? supports_concurrent_connections?
        supports_datetime_with_precision? supports_disable_referential_integrity? supports_explain?
        supports_expression_index? supports_foreign_keys? supports_insert_on_duplicate_skip?
        supports_insert_on_duplicate_update? supports_json? supports_optimizer_hints?
        supports_restart_db_transaction? supports_views? supports_virtual_columns?
      ).sort!)
      answers["supports_ddl_transactions?"].should be_false
      answers["supports_partial_index?"].should be_false
      answers["supports_insert_returning?"].should be_false
    end

    it "gates on the MySQL release" do
      mysql_at(5, 6, 3).supports_datetime_with_precision?.should be_false
      mysql_at(5, 6, 4).supports_datetime_with_precision?.should be_true
      mysql_at(5, 7, 7).supports_json?.should be_false
      mysql_at(5, 7, 8).supports_json?.should be_true
      mysql_at(8, 0, 15).supports_check_constraints?.should be_false
      mysql_at(8, 0, 16).supports_check_constraints?.should be_true
      mysql_at(8, 0, 0).supports_common_table_expressions?.should be_false
      mysql_at(8, 0, 1).supports_common_table_expressions?.should be_true
      mysql_at(8, 0, 12).supports_expression_index?.should be_false
      mysql_at(8, 0, 13).supports_expression_index?.should be_true
    end

    it "uses MariaDB's own version line" do
      maria = mysql_at(10, 6, 12, mariadb: true)
      maria.supports_insert_returning?.should be_true
      maria.supports_optimizer_hints?.should be_false
      maria.supports_expression_index?.should be_false
      maria.supports_check_constraints?.should be_true
      mysql_at(10, 4, 0, mariadb: true).supports_insert_returning?.should be_false
    end

    it "names itself" do
      mysql_at(8, 0, 35).adapter_name.should eq("MySQL")
    end
  end

  describe "SQLite" do
    it "answers each predicate on SQLite 3.45" do
      answers = capability_answers(sqlite_at(3, 45))
      answers.select { |_, value| value }.keys.sort!.should eq(%w(
        supports_check_constraints? supports_common_table_expressions? supports_concurrent_connections?
        supports_datetime_with_precision? supports_ddl_transactions? supports_disable_referential_integrity?
        supports_explain? supports_expression_index? supports_foreign_keys? supports_insert_on_duplicate_skip?
        supports_insert_on_duplicate_update? supports_insert_returning? supports_json?
        supports_partial_index? supports_views? supports_virtual_columns?
      ).sort!)
      answers["supports_comments?"].should be_false
      answers["supports_advisory_locks?"].should be_false
      answers["supports_bulk_alter?"].should be_false
      answers["supports_restart_db_transaction?"].should be_false
    end

    it "gates on the SQLite release" do
      sqlite_at(3, 34).supports_insert_returning?.should be_false
      sqlite_at(3, 35).supports_insert_returning?.should be_true
      sqlite_at(3, 37).supports_json?.should be_false
      sqlite_at(3, 38).supports_json?.should be_true
      sqlite_at(3, 30).supports_virtual_columns?.should be_false
      sqlite_at(3, 31).supports_virtual_columns?.should be_true
    end

    it "does not offer concurrent connections to an in-memory database" do
      sqlite_at(3, 45, url: "sqlite3::memory:").supports_concurrent_connections?.should be_false
      sqlite_at(3, 45).supports_concurrent_connections?.should be_true
    end

    it "names itself" do
      sqlite_at(3, 45).adapter_name.should eq("SQLite")
    end
  end

  describe "cached database_version" do
    it "returns the same version on every call" do
      adapter = Parent.adapter
      first = adapter.database_version
      adapter.database_version.should eq(first)
    end

    it "lets a pinned version drive the gated predicates without a query" do
      # The URL is unusable: a query would raise instead of answering.
      adapter = pg_at(17)
      adapter.supports_virtual_columns?.should be_true
      adapter.supports_nulls_not_distinct?.should be_true

      adapter.database_version = G01Version.new(11)
      adapter.supports_virtual_columns?.should be_false
    end

    it "fetches once, then reuses the cache" do
      adapter = G01CountingAdapter.new("g01_counting", "counting://unused")
      3.times { adapter.supports_json? }
      adapter.fetches.should eq(1)
    end
  end

  describe "identity on the #{CURRENT_ADAPTER} adapter" do
    it "reports the adapter name" do
      expected = case CURRENT_ADAPTER
                 when "pg"    then "PostgreSQL"
                 when "mysql" then "MySQL"
                 else              "SQLite"
                 end
      Parent.adapter.adapter_name.should eq(expected)
    end

    it "reads the server version" do
      version = Parent.adapter.database_version
      (version.major > 0).should be_true
      case CURRENT_ADAPTER
      when "pg"     then (version.major >= 12).should be_true
      when "sqlite" then version.should eq(G01Version.parse(Grant::SQLiteVersionCheck.version_string))
      end
    end

    it "reports the current database" do
      name = Parent.adapter.current_database
      name.should_not be_empty
      case CURRENT_ADAPTER
      when "pg"     then name.should eq(URI.parse(ADAPTER_URL).path.lstrip('/'))
      when "sqlite" then name.should contain(File.basename(ADAPTER_URL.split('?').first))
      end
    end

    it "yields the raw connection through with_connection" do
      Parent.adapter.with_connection do |connection|
        connection.should be_a(DB::Connection)
        connection.scalar("SELECT 1").to_s.should eq("1")
      end
    end
  end
end
