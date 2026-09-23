require "../spec_helper"

{% begin %}
  {% raw_sql_adapter = env("CURRENT_ADAPTER").id %}

  class RawSqlParityRecord < Grant::Base
    connection {{ raw_sql_adapter }}
    table raw_sql_parity_records

    column id : Int64, primary: true
    column label : String
    column active : Bool
  end

  class RawSqlScopedParityRecord < Grant::Base
    connection {{ raw_sql_adapter }}
    table raw_sql_parity_records

    column id : Int64, primary: true
    column label : String
    column active : Bool

    default_scope { where(active: true) }
  end

  class RawSqlRoutedParityRecord < Grant::Base
    connection {{ raw_sql_adapter }}
    table raw_sql_parity_records

    column id : Int64, primary: true
    column label : String
    column active : Bool
  end
{% end %}

RawSqlRoutedParityRecord.connection_config = {
  :writing => CURRENT_ADAPTER,
  :reading => "#{CURRENT_ADAPTER}_with_replica",
}

class RawSqlRollbackError < Exception
end

private def raw_sql_adapter : Grant::Adapter::Base
  Grant::ConnectionRegistry.get_adapter(CURRENT_ADAPTER, :writing)
end

raw_sql_adapter().open do |database|
  database.exec("DROP TABLE IF EXISTS raw_sql_parity_records")
  database.exec(<<-SQL)
    CREATE TABLE raw_sql_parity_records (
      id BIGINT PRIMARY KEY,
      label TEXT NOT NULL,
      active BOOLEAN NOT NULL
    )
    SQL
end

Spec.before_each do
  raw_sql_adapter().open do |database|
    database.exec("DELETE FROM raw_sql_parity_records")
    database.exec("INSERT INTO raw_sql_parity_records (id, label, active) VALUES (1, 'alpha', TRUE), (2, 'hidden', FALSE)")
  end
end

describe "ActiveRecord-style raw SQL" do
  it "hydrates find_by_sql results and binds their values" do
    records = RawSqlParityRecord.find_by_sql(
      "SELECT * FROM raw_sql_parity_records WHERE label = ?",
      ["alpha"]
    )

    records.size.should eq(1)
    records.first.label.should eq("alpha")
    records.first.persisted?.should be_true
  end

  it "counts arbitrary SQL with bound parameters as Int64" do
    RawSqlParityRecord.count_by_sql(
      "SELECT COUNT(*) FROM raw_sql_parity_records WHERE active = ?",
      [true]
    ).should eq(1_i64)
  end

  it "keeps an injection payload inert in a model-level bind" do
    payload = "alpha' OR 1=1 --"

    RawSqlParityRecord.find_by_sql(
      "SELECT * FROM raw_sql_parity_records WHERE label = ?",
      [payload]
    ).should be_empty
    RawSqlParityRecord.count_by_sql(
      "SELECT COUNT(*) FROM raw_sql_parity_records WHERE label = ?",
      [payload]
    ).should eq(0_i64)
  end

  it "supports bound exec and scalar calls, including the block form" do
    RawSqlParityRecord.exec(
      "INSERT INTO raw_sql_parity_records (id, label, active) VALUES (?, ?, ?)",
      [3_i64, "gamma", true]
    )

    RawSqlParityRecord.scalar(
      "SELECT label FROM raw_sql_parity_records WHERE id = ?",
      [3_i64]
    ).should eq("gamma")

    RawSqlParityRecord.scalar(
      "SELECT label FROM raw_sql_parity_records WHERE id = ?",
      [1_i64]
    ) { |value| value }.should eq("alpha")
  end

  it "marks model scalar calls as writes for every overload" do
    before_unbound_scalar = RawSqlParityRecord.last_write_time
    sleep 1.millisecond
    RawSqlParityRecord.scalar(
      "SELECT id FROM raw_sql_parity_records WHERE label = 'alpha'"
    ).should eq(1_i64)
    after_unbound_scalar = RawSqlParityRecord.last_write_time
    after_unbound_scalar.should be > before_unbound_scalar

    sleep 1.millisecond
    RawSqlParityRecord.scalar(
      "SELECT id FROM raw_sql_parity_records WHERE id = ?",
      [2_i64]
    ).should eq(2_i64)
    after_bound_scalar = RawSqlParityRecord.last_write_time
    after_bound_scalar.should be > after_unbound_scalar

    sleep 1.millisecond
    RawSqlParityRecord.scalar(
      "SELECT id FROM raw_sql_parity_records WHERE id = 1"
    ) { |value| value }.should eq(1_i64)
    after_unbound_block_scalar = RawSqlParityRecord.last_write_time
    after_unbound_block_scalar.should be > after_bound_scalar

    sleep 1.millisecond
    RawSqlParityRecord.scalar(
      "SELECT id FROM raw_sql_parity_records WHERE label = ?",
      ["hidden"]
    ) { |value| value }.should eq(2_i64)
    after_bound_block_scalar = RawSqlParityRecord.last_write_time
    after_bound_block_scalar.should be > after_unbound_block_scalar
  end

  it "keeps connection select_value a pure read for write tracking" do
    last_write_time = RawSqlParityRecord.last_write_time

    RawSqlParityRecord.connection.select_value("SELECT COUNT(*) FROM raw_sql_parity_records")
      .should eq(2_i64)

    RawSqlParityRecord.last_write_time.should eq(last_write_time)
  end

  it "exposes raw connection results and all select helpers" do
    connection = RawSqlParityRecord.connection
    result = connection.exec_query(
      "SELECT id, label FROM raw_sql_parity_records WHERE id = ?",
      [1_i64]
    )

    result.should be_a(Grant::Result)
    result.columns.should eq(["id", "label"])
    result.rows.size.should eq(1)
    result.size.should eq(1)
    result.empty?.should be_false
    result.to_a.first["label"].should eq("alpha")

    yielded_rows = [] of Hash(String, DB::Any)
    result.each { |row| yielded_rows << row }
    yielded_rows.size.should eq(1)

    connection.select_all(
      "SELECT id, label FROM raw_sql_parity_records WHERE id = ?",
      [1_i64]
    ).size.should eq(1)
    connection.select_all("SELECT id FROM raw_sql_parity_records WHERE id = ?", [0_i64]).empty?.should be_true
    connection.select_one("SELECT label FROM raw_sql_parity_records WHERE id = ?", [1_i64])
      .try { |row| row["label"] }.should eq("alpha")
    connection.select_value("SELECT label FROM raw_sql_parity_records WHERE id = ?", [1_i64]).should eq("alpha")
    connection.select_values("SELECT label FROM raw_sql_parity_records WHERE id >= ? ORDER BY id", [1_i64]).should eq(["alpha", "hidden"])

    selected_rows = connection.select_rows("SELECT id, label FROM raw_sql_parity_records WHERE id >= ? ORDER BY id", [1_i64])
    selected_rows.size.should eq(2)
    selected_rows.first.first.should eq(1_i64)
    selected_rows.first.last.should eq("alpha")
  end

  it "binds connection execute values and keeps an injection payload inert" do
    connection = RawSqlParityRecord.connection
    payload = "alpha' OR 1=1 --"

    result = connection.execute(
      "INSERT INTO raw_sql_parity_records (id, label, active) VALUES (?, ?, ?)",
      [3_i64, payload, true]
    )
    result.rows_affected.should eq(1_i64)
    connection.select_value(
      "SELECT COUNT(*) FROM raw_sql_parity_records WHERE label = ?",
      [payload]
    ).should eq(1_i64)
    connection.select_value("SELECT COUNT(*) FROM raw_sql_parity_records").should eq(3_i64)
  end

  it "reaches a named connection through Grant.connection" do
    Grant.connection(CURRENT_ADAPTER)
      .select_value("SELECT COUNT(*) FROM raw_sql_parity_records")
      .should eq(2_i64)
  end

  it "routes model and named connection operations through configured roles" do
    model_connection = RawSqlRoutedParityRecord.connection
    model_connection.adapter(:writing).name.should eq(Grant::ConnectionRegistry.get_adapter(CURRENT_ADAPTER, :writing).name)

    RawSqlRoutedParityRecord.connected_to(role: :reading) do
      reader_connection = RawSqlRoutedParityRecord.connection
      reader_connection.adapter.name.should eq(Grant::ConnectionRegistry.get_adapter("#{CURRENT_ADAPTER}_with_replica", :reading).name)
      reader_connection.select_value("SELECT 7").to_s.should eq("7")
    end

    named_connection = Grant.connection("#{CURRENT_ADAPTER}_with_replica")
    named_connection.adapter(:writing).name.should eq(Grant::ConnectionRegistry.get_adapter("#{CURRENT_ADAPTER}_with_replica", :writing).name)
    named_connection.adapter(:reading).name.should eq(Grant::ConnectionRegistry.get_adapter("#{CURRENT_ADAPTER}_with_replica", :reading).name)
  end

  it "uses the active model transaction for raw connection writes" do
    expect_raises(RawSqlRollbackError) do
      RawSqlParityRecord.transaction do
        RawSqlParityRecord.connection.execute(
          "INSERT INTO raw_sql_parity_records (id, label, active) VALUES (?, ?, ?)",
          [9_i64, "rolled back", true]
        )
        raise RawSqlRollbackError.new("rollback")
      end
    end

    RawSqlParityRecord.count_by_sql("SELECT COUNT(*) FROM raw_sql_parity_records WHERE id = ?", [9_i64]).should eq(0_i64)
  end

  it "exposes ActiveRecord-shaped sanitization class methods" do
    expected = "label = 'O''Brien'"

    RawSqlParityRecord.sanitize_sql_array(["label = ?", "O'Brien"]).should eq(expected)
    RawSqlParityRecord.sanitize_sql(["label = ?", "O'Brien"]).should eq(expected)
    RawSqlParityRecord.sanitize_sql("SELECT 1").should eq("SELECT 1")
  end

  it "requires unscoped for model raw SQL and leaves connection calls explicitly raw" do
    expect_raises(Grant::Querying::ScopedRawSqlError) do
      RawSqlScopedParityRecord.find_by_sql("SELECT * FROM raw_sql_parity_records")
    end
    expect_raises(Grant::Querying::ScopedRawSqlError) do
      RawSqlScopedParityRecord.count_by_sql("SELECT COUNT(*) FROM raw_sql_parity_records")
    end
    expect_raises(Grant::Querying::ScopedRawSqlError) do
      RawSqlScopedParityRecord.scalar("SELECT COUNT(*) FROM raw_sql_parity_records")
    end
    expect_raises(Grant::Querying::ScopedRawSqlError) do
      RawSqlScopedParityRecord.exec("DELETE FROM raw_sql_parity_records")
    end

    RawSqlScopedParityRecord.unscoped do
      RawSqlScopedParityRecord.exec(
        "INSERT INTO raw_sql_parity_records (id, label, active) VALUES (?, ?, ?)",
        [3_i64, "unscoped insert", true]
      )
    end

    scoped_count = RawSqlScopedParityRecord.unscoped do
      RawSqlScopedParityRecord.count_by_sql("SELECT COUNT(*) FROM raw_sql_parity_records")
    end
    scoped_count.should eq(3_i64)

    unscoped_records = RawSqlScopedParityRecord.unscoped do
      RawSqlScopedParityRecord.find_by_sql("SELECT * FROM raw_sql_parity_records ORDER BY id")
    end
    unscoped_records.map(&.label).should eq(["alpha", "hidden", "unscoped insert"])

    scoped_connection = RawSqlScopedParityRecord.connection
    scoped_connection.select_values("SELECT label FROM raw_sql_parity_records ORDER BY id").should eq(["alpha", "hidden", "unscoped insert"])
    scoped_connection.execute(
      "INSERT INTO raw_sql_parity_records (id, label, active) VALUES (?, ?, ?)",
      [4_i64, "connection insert", false]
    )
    scoped_connection.select_values("SELECT label FROM raw_sql_parity_records ORDER BY id").should eq(["alpha", "hidden", "unscoped insert", "connection insert"])
  end
end

{% if env("CURRENT_ADAPTER") == "pg" %}
  describe "raw SQL on schema-tenant connections" do
    schema = "grant_raw_sql_connection_tenant"

    before_all do
      Grant::SchemaTenant.drop_schema(schema, adapter: raw_sql_adapter(), cascade: true)
      Grant::SchemaTenant.create_schema(schema, adapter: raw_sql_adapter())
      raw_sql_adapter().open do |database|
        database.exec("CREATE TABLE #{raw_sql_adapter().quote(schema)}.raw_sql_parity_records (id BIGINT PRIMARY KEY, label TEXT NOT NULL, active BOOLEAN NOT NULL)")
      end
    end

    after_all do
      Grant::SchemaTenant.drop_schema(schema, adapter: raw_sql_adapter(), cascade: true)
    end

    it "uses and restores the pinned tenant connection for read and write calls" do
      Grant::SchemaTenant.with(schema, adapter: raw_sql_adapter()) do
        RawSqlParityRecord.connection.select_value("SELECT current_schema()").should eq(schema)
        RawSqlParityRecord.connection.execute(
          "INSERT INTO raw_sql_parity_records (id, label, active) VALUES (?, ?, ?)",
          [11_i64, "tenant row", true]
        )
        RawSqlParityRecord.connection.select_value(
          "SELECT COUNT(*) FROM raw_sql_parity_records WHERE label = ?",
          ["tenant row"]
        ).should eq(1_i64)
      end

      RawSqlParityRecord.connection.select_value("SELECT current_schema()").should eq("public")
      raw_sql_adapter().open do |database|
        database.query_one("SELECT COUNT(*) FROM #{raw_sql_adapter().quote(schema)}.raw_sql_parity_records", as: Int64).should eq(1_i64)
      end
    end
  end
{% end %}
