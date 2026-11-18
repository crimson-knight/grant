require "../spec_helper"
require "log/spec"

# Issue #63: an app model named `Connection` shares its name with
# `Grant::Connection`. The table-to-model map built in `src/grant/log.cr`, the
# polymorphic loaders and the STI registry generate code inside the Grant
# namespace and must reach the app's top-level models, so this file compiling
# at all is the first half of the proof; the specs below prove the models also
# save, load and log. `Transaction` (an STI root here) shares its name with
# the `Grant::Transaction` module.
{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class Connection < Grant::Base
    connection {{ adapter_literal }}
    table top_level_connections

    column id : Int64, primary: true
    column host_address : String

    register_polymorphic_type
  end

  class Transaction < Grant::Base
    include Grant::STI
    connection {{ adapter_literal }}
    table top_level_transactions

    column id : Int64, primary: true
    column type : String
    column amount_cents : Int64
  end

  class TransactionRefund < Transaction
  end
{% end %}

private def top_level_connection_sql_messages(& : ->) : Array(String)
  backend = Log::MemoryBackend.new
  Log.builder.bind("grant.sql", Log::Severity::Debug, backend)
  begin
    yield
  ensure
    Log.builder.unbind("grant.sql", Log::Severity::Debug, backend)
  end
  backend.entries.compact_map(&.message)
end

describe "A top-level model named Connection" do
  before_all do
    ::Connection.migrator.drop_and_create
    ::Transaction.migrator.drop_and_create
  end

  before_each do
    ::Connection.clear
    Grant::Logs.verbose_query_logs = true
  end

  after_each do
    Grant::Logs.verbose_query_logs = false
  end

  it "maps its table to the top-level model, not Grant::Connection" do
    Grant::Logs.model_name_for_table("top_level_connections").should eq("Connection")
  end

  it "saves and labels its verbose query logs with the model name" do
    record = ::Connection.new(host_address: "db.example.test")
    messages = top_level_connection_sql_messages { record.save! }

    record.persisted?.should be_true
    labels = messages.select(&.includes?("↳")).map(&.split(" (").first)
    labels.should eq(["Connection Create"])
  end

  it "loads through the polymorphic registry as the top-level model" do
    record = ::Connection.create!(host_address: "poly.example.test")
    loaded = Grant::Polymorphic.load_polymorphic("Connection", record.id)
    loaded.should be_a(::Connection)
    loaded.as(::Connection).host_address.should eq "poly.example.test"
  end

  it "resolves and rehomes an STI model named like a Grant module" do
    Grant::STI.find_sti_class_by_name("Transaction").should eq ::Transaction
    ::TransactionRefund.create!(amount_cents: 250_i64)
    ::Transaction.all.map(&.class).should eq [::TransactionRefund]
  end
end
