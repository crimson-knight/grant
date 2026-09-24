require "../spec_helper"

{% begin %}
  {% result_adapter = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class GrantResultValueProbe < Grant::Base
    connection {{ result_adapter }}
    table grant_result_value_probes

    column id : Int64, primary: true
    column occurred_at : Time
    column identifier : UUID
  end
{% end %}

describe "Grant::Result driver values" do
  before_all do
    GrantResultValueProbe.migrator.drop_and_create
  end

  it "binds and reads model Time and UUID values through Grant's adapter boundary" do
    occurred_at = Time.utc(2026, 9, 24, 12, 30, 40, nanosecond: 123_456_000)
    identifier = UUID.new("8d1c7e9b-36b5-4e89-a881-d3bb6c761a19")

    GrantResultValueProbe.create!(occurred_at: occurred_at, identifier: identifier)
    loaded = GrantResultValueProbe.first

    loaded.should_not be_nil
    loaded.not_nil!.occurred_at.should eq(occurred_at)
    loaded.not_nil!.identifier.should eq(identifier)
  end

  {% if env("CURRENT_ADAPTER") == "pg" %}
    it "normalizes PostgreSQL numeric while preserving UUID, smallint, and JSON" do
      result = Grant.connection("pg").exec_query(
        "SELECT 1.5::numeric AS amount, " \
        "'8d1c7e9b-36b5-4e89-a881-d3bb6c761a19'::uuid AS identifier, " \
        "7::smallint AS small_number, '{\"ok\":true}'::json AS payload"
      )

      row = result.rows.first
      row[0].should eq("1.5")
      row[1].class.should eq(UUID)
      row[2].class.should eq(Int16)
      row[3].class.should eq(JSON::Any)

      array_value = Grant.connection("pg").select_value("SELECT ARRAY[1, 2]::smallint[]")
      array_value.should eq("[1, 2]")
    end

    it "returns PostgreSQL numeric values from Model.scalar unchanged" do
      value = GrantResultValueProbe.scalar("SELECT 1.5::numeric")

      value.should_not be_nil
      value.class.should eq(PG::Numeric)
      value.to_s.should eq("1.5")
    end

    it "counts a PostgreSQL SUM over numeric values" do
      GrantResultValueProbe.count_by_sql(
        "SELECT SUM(amount) FROM (VALUES (1.5::numeric), (2.5::numeric)) AS amounts(amount)"
      ).should eq(4_i64)
    end
  {% else %}
    {% if env("CURRENT_ADAPTER") == "mysql" %}
      it "preserves MySQL JSON text returned by the driver's JSON decoder" do
        value = Grant.connection("mysql").select_value("SELECT CAST('{\"ok\": true}' AS JSON)")
        value.should eq("{\"ok\": true}")
      end

      it "buffers MySQL numeric and integer values returned by the driver" do
        result = Grant.connection("mysql").exec_query("SELECT 1.5 AS amount, CAST(7 AS SIGNED) AS small_number")

        result.rows.first[0].should eq(1.5)
        result.rows.first[1].should eq(7_i64)
      end
    {% end %}

    it "preserves the adapter's native numeric scalar value" do
      value = GrantResultValueProbe.scalar("SELECT 1.5")

      value.should_not be_nil
      {% if env("CURRENT_ADAPTER") == "mysql" %}
        value.class.should eq(Float64)
        value.to_s.should eq("1.5")
      {% else %}
        value.class.should eq(Float64)
        value.to_s.should eq("1.5")
      {% end %}
    end

    it "counts a SUM over the adapter's numeric values" do
      {% if env("CURRENT_ADAPTER") == "mysql" %}
        GrantResultValueProbe.count_by_sql("SELECT SUM(amount) FROM (SELECT 1.5 AS amount UNION ALL SELECT 2.5 AS amount) AS amounts").should eq(4_i64)
      {% else %}
        GrantResultValueProbe.count_by_sql("SELECT SUM(amount) FROM (SELECT 1.5 AS amount UNION ALL SELECT 2.5 AS amount)").should eq(4_i64)
      {% end %}
    end
  {% end %}
end
