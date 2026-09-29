require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class ReadOnlyTxRow < Grant::Base
    connection {{ adapter_literal }}
    table read_only_tx_rows

    column id : Int64, primary: true
    column name : String?
  end
{% end %}

ReadOnlyTxRow.migrator.drop_and_create

describe "create inside a read-only transaction" do
  before_each { ReadOnlyTxRow.clear }

  # SQLite has no read-only transaction mode; the database enforces it on
  # PostgreSQL and MySQL only.
  unless CURRENT_ADAPTER == "sqlite"
    it "surfaces ReadOnlyError from create!" do
      expect_raises(Grant::Transaction::ReadOnlyError) do
        ReadOnlyTxRow.transaction(readonly: true) { ReadOnlyTxRow.create!(name: "blocked") }
      end
      ReadOnlyTxRow.count.should eq(0)
    end

    it "surfaces ReadOnlyError from save!" do
      row = ReadOnlyTxRow.new(name: "blocked")
      expect_raises(Grant::Transaction::ReadOnlyError) do
        ReadOnlyTxRow.transaction(readonly: true) { row.save! }
      end
    end

    it "surfaces ReadOnlyError from update!" do
      row = ReadOnlyTxRow.create!(name: "kept")
      expect_raises(Grant::Transaction::ReadOnlyError) do
        ReadOnlyTxRow.transaction(readonly: true) { row.update!(name: "blocked") }
      end
      ReadOnlyTxRow.find!(row.id).name.should eq("kept")
    end
  end

  it "keeps a translated statement error as the cause of RecordNotSaved" do
    ReadOnlyTxRow.create!(id: 7_i64, name: "first")
    error = expect_raises(Grant::RecordNotSaved) do
      ReadOnlyTxRow.create!(id: 7_i64, name: "duplicate")
    end
    error.cause.should be_a(Grant::StatementInvalid)
  end
end
