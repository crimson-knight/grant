require "../spec_helper"
require "log/spec"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6bVlGadget < Grant::Base
    connection {{ adapter_literal }}
    table w6b_vl_gadgets

    column id : Int64, primary: true
    column label : String
  end
{% end %}

private def w6b_sql_messages(& : ->) : Array(String)
  backend = Log::MemoryBackend.new
  Log.builder.bind("grant.sql", Log::Severity::Debug, backend)
  begin
    yield
  ensure
    Log.builder.unbind("grant.sql", Log::Severity::Debug, backend)
  end
  backend.entries.compact_map(&.message)
end

private def w6b_verbose_labels(messages : Array(String)) : Array(String)
  messages.select(&.includes?("↳")).map { |message| message.split(" (").first }
end

describe "Verbose query logs label statements by model" do
  before_all do
    W6bVlGadget.migrator.drop_and_create
  end

  before_each do
    W6bVlGadget.clear
    Grant::Logs.verbose_query_logs = true
  end

  after_each do
    Grant::Logs.verbose_query_logs = false
  end

  it "names the model, not the table, on record writes" do
    gadget = W6bVlGadget.new(label: "a")
    messages = w6b_sql_messages do
      gadget.save!
      gadget.update!(label: "b")
      gadget.destroy
    end

    w6b_verbose_labels(messages).should eq(["W6bVlGadget Create", "W6bVlGadget Update", "W6bVlGadget Destroy"])
  end

  it "labels relation reads with the model as before" do
    w6b_verbose_labels(w6b_sql_messages { W6bVlGadget.where(label: "x").to_a }).should eq(["W6bVlGadget Load"])
  end

  it "emits a verbose line for raw Model.exec, Model.query and Model.scalar" do
    messages = w6b_sql_messages do
      W6bVlGadget.exec("UPDATE w6b_vl_gadgets SET label = label")
      W6bVlGadget.query("SELECT label FROM w6b_vl_gadgets") { |rs| rs.each { rs.read(String) } }
      W6bVlGadget.scalar("SELECT COUNT(*) FROM w6b_vl_gadgets")
    end

    labels = messages.select(&.starts_with?("W6bVlGadget ")).map { |message| message.split(" (").first }
    labels.should eq(["W6bVlGadget Update", "W6bVlGadget Load", "W6bVlGadget Load"])
    # `exec` and `scalar` are real calls, so their frame reaches the spec; `query`
    # yields, which Crystal inlines into the caller, leaving no frame to report.
    messages.select(&.includes?("↳")).each { |line| line.should contain("w6b_verbose_logs_model_label_spec.cr:") }
  end

  it "emits a verbose line for Grant.connection reads and writes" do
    messages = w6b_sql_messages do
      Grant.connection.execute("DELETE FROM w6b_vl_gadgets")
      Grant.connection.select_value("SELECT COUNT(*) FROM w6b_vl_gadgets")
    end

    w6b_verbose_labels(messages).should eq(["W6bVlGadget Destroy", "W6bVlGadget Load"])
  end

  it "emits a verbose line for the cache-version query" do
    messages = w6b_sql_messages { W6bVlGadget.where(label: "x").cache_version }

    w6b_verbose_labels(messages).should eq(["W6bVlGadget Load"])
  end

  it "keeps the bind values in the SQL log entry" do
    messages = w6b_sql_messages { W6bVlGadget.where(label: "needle").to_a }

    messages.reject(&.includes?("↳")).any?(&.includes?("needle")).should be_true
  end

  it "adds nothing for raw statements while verbose logging is off" do
    Grant::Logs.verbose_query_logs = false
    messages = w6b_sql_messages { W6bVlGadget.exec("UPDATE w6b_vl_gadgets SET label = label") }

    messages.none?(&.includes?("↳")).should be_true
  end

  it "falls back to the table name for a table no model owns" do
    Grant::Logs.model_name_for_table("no_such_table").should be_nil
    Grant::Logs.model_name_for_table("w6b_vl_gadgets").should eq("W6bVlGadget")
  end
end
