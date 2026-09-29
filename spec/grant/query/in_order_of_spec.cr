require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class IoTicket < Grant::Base
    connection {{ adapter_literal }}
    table io_tickets
    column id : Int64, primary: true
    column status : String?
    column priority : Int64
  end
{% end %}

describe "in_order_of" do
  before_all { IoTicket.migrator.drop_and_create }

  before_each do
    IoTicket.clear
    IoTicket.create!(status: "done", priority: 1_i64)
    IoTicket.create!(status: "open", priority: 2_i64)
    IoTicket.create!(status: "blocked", priority: 3_i64)
    IoTicket.create!(status: "open", priority: 4_i64)
    IoTicket.create!(status: nil, priority: 5_i64)
  end

  it "orders by the position in the list and filters to the listed values" do
    result = IoTicket.in_order_of(:status, ["open", "done"]).order(:priority).select
    result.map(&.status).should eq(["open", "open", "done"])
    result.map(&.priority).should eq([2_i64, 4_i64, 1_i64])
  end

  it "filters by default (filter: true) with a bound IN list" do
    relation = IoTicket.in_order_of(:status, ["open", "done"])
    relation.select.size.should eq(3)
    relation.raw_sql.should contain("IN (")
    relation.raw_sql.should contain("CASE WHEN")
  end

  it "keeps the other rows after the listed ones with filter: false" do
    result = IoTicket.in_order_of(:status, ["blocked", "done"], filter: false).order(:priority).select
    result.map(&.status).first(2).should eq(["blocked", "done"])
    result.size.should eq(5)
  end

  it "matches NULL for a nil member" do
    result = IoTicket.in_order_of(:status, [nil, "done"]).select
    result.map(&.status).should eq([nil, "done"])
  end

  it "orders integers too, and takes the column as a string" do
    IoTicket.in_order_of("priority", [4_i64, 1_i64, 2_i64]).select.map(&.priority).should eq([4_i64, 1_i64, 2_i64])
  end

  it "composes with other ordering, in call order" do
    IoTicket.order(:priority).in_order_of(:status, ["open", "done"]).select.map(&.priority).should eq([1_i64, 2_i64, 4_i64])
    IoTicket.in_order_of(:status, ["open", "done"]).order(priority: :desc).select.map(&.priority).should eq([4_i64, 2_i64, 1_i64])
  end

  it "returns no rows for an empty list" do
    IoTicket.in_order_of(:status, [] of String).select.should be_empty
  end

  it "escapes quote characters in string values" do
    IoTicket.create!(status: "it's ; DROP TABLE io_tickets --", priority: 6_i64)
    result = IoTicket.in_order_of(:status, ["it's ; DROP TABLE io_tickets --", "done"]).select
    result.map(&.priority).should eq([6_i64, 1_i64])
    IoTicket.count.should eq(6_i64)
  end

  it "escapes a backslash in string values" do
    IoTicket.create!(status: "back\\slash", priority: 7_i64)
    IoTicket.in_order_of(:status, ["back\\slash"]).select.map(&.priority).should eq([7_i64])
  end

  it "matches a backslash and quote value in the ORDER BY literal itself" do
    IoTicket.create!(status: "a\\'b", priority: 8_i64)
    ordered = IoTicket.in_order_of(:status, ["a\\'b"], filter: false).order(:priority).select
    ordered.first.priority.should eq(8_i64)
  end

  it "writes PostgreSQL string literals as E'' so backslashes never depend on server settings" do
    {% if env("CURRENT_ADAPTER") == "pg" %}
      IoTicket.in_order_of(:status, ["x\\y"]).raw_sql.should contain("E'x\\\\y'")
    {% else %}
      IoTicket.in_order_of(:status, ["x\\y"]).raw_sql.should_not contain("E'")
    {% end %}
  end

  it "caps the list size" do
    values = Array.new(Grant::Query::OrderSupport::IN_ORDER_OF_LIMIT + 1) { |index| "v#{index}" }
    expect_raises(ArgumentError, /at most 1000 values/) { IoTicket.in_order_of(:status, values) }
    IoTicket.in_order_of(:status, values.first(Grant::Query::OrderSupport::IN_ORDER_OF_LIMIT)).select.should be_empty
  end

  it "rejects a column that is not a name" do
    expect_raises(ArgumentError, /takes a column name/) { IoTicket.in_order_of("status; --", ["open"]) }
  end

  it "reverses with the rest of the order" do
    IoTicket.in_order_of(:status, ["open", "done"]).order(:priority).reverse_order.select.map(&.priority).should eq([1_i64, 4_i64, 2_i64])
  end

  it "does not change the receiver" do
    base = IoTicket.where(priority: 2_i64)
    base.in_order_of(:status, ["open"])
    base.order_fields.should be_empty
    base.where_fields.size.should eq(1)
  end

  it "has a bang form" do
    relation = IoTicket.all
    relation.in_order_of!(:status, ["open"])
    relation.order_fields.size.should eq(1)
  end
end
