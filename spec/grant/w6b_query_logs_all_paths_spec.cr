require "../spec_helper"
require "../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6bQlItem < Grant::Base
    connection {{ adapter_literal }}
    table w6b_ql_items

    column id : Int64, primary: true
    column sku : String
    column qty : Int32 = 0
    column hits : Int32 = 0
    column updated_at : Time?
  end
{% end %}

TAG_COMMENT = "/*application:w6b*/"

# Every statement the block sends that touches the items table.
private def item_statements(& : ->) : Array(String)
  StatementRecorder.statements { yield }.select(&.includes?("w6b_ql_items"))
end

private def tagged!(statements : Array(String), verb : String? = nil) : Nil
  scoped = verb ? statements.select(&.lstrip.upcase.starts_with?(verb)) : statements
  scoped.should_not be_empty
  scoped.each(&.should(end_with(TAG_COMMENT)))
end

describe "Grant::QueryLogs on every statement path" do
  before_all do
    W6bQlItem.migrator.drop_and_create
  end

  before_each do
    Grant::QueryLogs.reset!
    W6bQlItem.clear
    W6bQlItem.create!(sku: "a", qty: 2)
    W6bQlItem.create!(sku: "b", qty: 5)
    Grant::QueryLogs.enabled = true
    Grant::QueryLogs.tag(:application, "w6b")
  end

  after_each do
    Grant::QueryLogs.reset!
  end

  it "tags raw Model.exec, Model.query and Model.scalar" do
    tagged!(item_statements { W6bQlItem.exec("UPDATE w6b_ql_items SET qty = qty WHERE sku = 'a'") })
    tagged!(item_statements { W6bQlItem.query("SELECT sku FROM w6b_ql_items") { |rs| rs.each { rs.read(String) } } })
    tagged!(item_statements { W6bQlItem.scalar("SELECT COUNT(*) FROM w6b_ql_items") })
  end

  it "tags the Grant.connection helpers" do
    connection = Grant.connection
    tagged!(item_statements { connection.execute("UPDATE w6b_ql_items SET qty = qty") })
    tagged!(item_statements { connection.exec_query("SELECT sku FROM w6b_ql_items") })
    tagged!(item_statements { connection.select_value("SELECT COUNT(*) FROM w6b_ql_items") })
    tagged!(item_statements { connection.with_result_set("SELECT sku FROM w6b_ql_items") { |rs| rs.each { rs.read(String) } } })
  end

  it "tags counter updates" do
    item = W6bQlItem.first!
    id = item.id.not_nil!
    tagged!(item_statements { W6bQlItem.increment_counter(:hits, id, 2) })
    tagged!(item_statements { W6bQlItem.update_counters(id, {:hits => 1}, touch: true) })
  end

  it "tags insert_all, insert_all!, upsert_all and the single-row forms" do
    # MySQL has no INSERT ... RETURNING, so it inserts without asking for ids.
    returning = CURRENT_ADAPTER == "mysql" ? nil : [:id]
    tagged!(item_statements { W6bQlItem.insert_all([{:sku => "c", :qty => 1}, {:sku => "d", :qty => 2}] of Hash(Symbol, String | Int32), returning: returning) }, "INSERT")
    tagged!(item_statements { W6bQlItem.insert_all!([{:sku => "e", :qty => 1}] of Hash(Symbol, String | Int32)) }, "INSERT")
    tagged!(item_statements { W6bQlItem.upsert_all([{:id => 1_i64, :sku => "a2", :qty => 9}] of Hash(Symbol, Int64 | String | Int32), unique_by: [:id]) }, "INSERT")
    tagged!(item_statements { W6bQlItem.upsert({:id => 2_i64, :sku => "b2", :qty => 9} of Symbol => Int64 | String | Int32, unique_by: [:id]) }, "INSERT")
  end

  it "tags aggregations, pluck, pick and update_all" do
    tagged!(item_statements { W6bQlItem.sum(:qty) })
    tagged!(item_statements { W6bQlItem.average(:qty) })
    tagged!(item_statements { W6bQlItem.maximum(:qty) })
    tagged!(item_statements { W6bQlItem.where(sku: "a").pluck(:sku) })
    tagged!(item_statements { W6bQlItem.where(sku: "a").pick(:sku) })
    tagged!(item_statements { W6bQlItem.where(sku: "a").update_all(qty: 7) })
    tagged!(item_statements { W6bQlItem.where(sku: "a").cache_version })
  end

  it "tags streaming reads" do
    tagged!(item_statements { W6bQlItem.all.find_each { |_| } }, "SELECT")
  end

  it "leaves every path untouched while disabled" do
    Grant::QueryLogs.enabled = false
    statements = item_statements do
      W6bQlItem.exec("UPDATE w6b_ql_items SET qty = qty")
      W6bQlItem.increment_counter(:hits, 1_i64)
      W6bQlItem.insert_all([{:sku => "z", :qty => 1}] of Hash(Symbol, String | Int32))
      W6bQlItem.sum(:qty)
    end
    statements.should_not be_empty
    statements.each(&.should_not(contain("/*")))
  end
end
