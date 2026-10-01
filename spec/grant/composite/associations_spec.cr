require "../../spec_helper"
require "../../support/composite_sql_recorder"
require "../../support/association_query_counter"

class CkAsItem < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table ck_as_items

  column id : Int64, primary: true
  column shop_id : Int64?
  column order_id : Int64?
  column sku : String?

  belongs_to :order, class_name: CkAsOrder, foreign_key: {:shop_id, :order_id}, primary_key: {:shop_id, :id}, inverse_of: :items
end

class CkAsReceipt < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table ck_as_receipts

  column id : Int64, primary: true
  column shop_id : Int64?
  column order_id : Int64?
  column total : Int32?

  belongs_to :order, class_name: CkAsOrder, foreign_key: {:shop_id, :order_id}
end

class CkAsOrder < Grant::Base
  include Grant::CompositePrimaryKey

  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table ck_as_orders

  column shop_id : Int64, primary: true, auto: false
  column id : Int64, primary: true, auto: false
  column title : String?
  composite_primary_key shop_id, id

  has_many :items, class_name: CkAsItem, foreign_key: {:shop_id, :order_id}, inverse_of: :order, dependent: :destroy
  has_one :receipt, class_name: CkAsReceipt, foreign_key: [:shop_id, :order_id], dependent: :nullify
end

private def make_order(shop : Int64, id : Int64, title : String = "o#{shop}-#{id}") : CkAsOrder
  CkAsOrder.create!(shop_id: shop, id: id, title: title)
end

# Two orders share the id 5 in different shops: only the whole tuple tells
# them apart.
private def seed_shared_ids
  order_one = make_order(1_i64, 5_i64)
  order_two = make_order(2_i64, 5_i64)
  CkAsItem.create!(shop_id: 1_i64, order_id: 5_i64, sku: "a1")
  CkAsItem.create!(shop_id: 1_i64, order_id: 5_i64, sku: "a2")
  CkAsItem.create!(shop_id: 2_i64, order_id: 5_i64, sku: "b1")
  {order_one, order_two}
end

describe "composite foreign keys on associations" do
  before_all do
    CkAsOrder.migrator.drop_and_create
    CkAsItem.migrator.drop_and_create
    CkAsReceipt.migrator.drop_and_create
  end

  before_each do
    CkAsItem.clear
    CkAsReceipt.clear
    CkAsOrder.clear
  end

  describe "has_many" do
    it "loads only the rows whose whole foreign key tuple matches" do
      order_one, order_two = seed_shared_ids
      order_one.items.to_a.map(&.sku.to_s).sort!.should eq ["a1", "a2"]
      order_two.items.to_a.map(&.sku.to_s).should eq ["b1"]
    end

    it "writes one statement with every foreign key column in its WHERE" do
      order_one, _ = seed_shared_ids
      statements = capture_statements { order_one.items.to_a }
      selects = statements.select(&.starts_with?("SELECT"))
      selects.size.should eq 1
      where_part(selects.first).should contain("shop_id")
      where_part(selects.first).should contain("order_id")
    end

    it "counts, checks emptiness and forwards relation methods" do
      order_one, order_two = seed_shared_ids
      order_one.items.size.should eq 2
      order_one.items.count.should eq 2
      order_one.items.empty?.should be_false
      order_one.items.where(sku: "a1").count.should eq 1
      order_one.items.order(:sku).first.not_nil!.sku.should eq "a1"
      order_two.items.any?.should be_true
      make_order(3_i64, 5_i64).items.empty?.should be_true
    end

    it "builds and creates children carrying the owner's whole key" do
      order = make_order(7_i64, 9_i64)
      built = order.items.build(sku: "built")
      built.shop_id.should eq 7_i64
      built.order_id.should eq 9_i64
      built.new_record?.should be_true

      created = order.items.create!(sku: "made")
      created.persisted?.should be_true
      CkAsItem.find!(created.id).shop_id.should eq 7_i64
      order.items.count.should eq 1
    end

    it "refuses to create through an unsaved owner" do
      order = CkAsOrder.new(shop_id: 1_i64, id: 1_i64)
      expect_raises(Grant::Associations::OwnerNotSaved) { order.items.create!(sku: "x") }
    end

    it "assigns a whole collection in memory" do
      order = make_order(4_i64, 4_i64)
      fresh = [CkAsItem.new(sku: "x"), CkAsItem.new(sku: "y")]
      order.items = fresh
      fresh.each do |item|
        item.shop_id.should eq 4_i64
        item.order_id.should eq 4_i64
      end
      order.items.size.should eq 2
    end
  end

  describe "belongs_to" do
    it "finds the parent by the whole tuple, not by order_id alone" do
      seed_shared_ids
      CkAsItem.find_by!(sku: "a1").order.not_nil!.shop_id.should eq 1_i64
      CkAsItem.find_by!(sku: "b1").order.not_nil!.shop_id.should eq 2_i64
    end

    it "returns nil for a partly or fully unset key and raises with the bang reader" do
      item = CkAsItem.new(sku: "orphan", order_id: 5_i64)
      item.order.should be_nil
      expect_raises(Grant::Querying::NotFound) { item.order! }
      item.shop_id = 9_i64
      item.order.should be_nil
    end

    it "queries once with every key column in the WHERE" do
      seed_shared_ids
      item = CkAsItem.find_by!(sku: "a1")
      statements = capture_statements { item.order }
      where = where_part(statements.find!(&.starts_with?("SELECT")))
      where.should contain("shop_id")
      where.should match(/(?<![A-Za-z_])id(?![A-Za-z_])/)
    end

    it "assigning a parent copies its key into the foreign key columns" do
      order = make_order(6_i64, 8_i64)
      item = CkAsItem.new(sku: "z")
      item.order = order
      item.shop_id.should eq 6_i64
      item.order_id.should eq 8_i64
      item.order.should eq order
      item.order = nil
      item.shop_id.should be_nil
      item.order_id.should be_nil
    end
  end

  describe "has_one" do
    it "loads the child by the whole tuple" do
      order_one, order_two = seed_shared_ids
      CkAsReceipt.create!(shop_id: 1_i64, order_id: 5_i64, total: 10)
      CkAsReceipt.create!(shop_id: 2_i64, order_id: 5_i64, total: 20)
      order_one.receipt.not_nil!.total.should eq 10
      order_two.receipt.not_nil!.total.should eq 20
      make_order(3_i64, 5_i64).receipt.should be_nil
    end
  end

  describe "preloading on tuples" do
    it "loads has_many for every owner with one query, never one per parent" do
      10_i64.times do |offset|
        order = make_order(1_i64 + offset % 3, 100_i64 + offset)
        order.items.create!(sku: "i#{offset}a")
        order.items.create!(sku: "i#{offset}b")
      end

      orders = [] of CkAsOrder
      statements = capture_statements { orders = CkAsOrder.includes(:items).to_a }
      statements.select(&.starts_with?("SELECT")).size.should eq 2

      orders.size.should eq 10
      orders.each do |order|
        order.association_loaded?(:items).should be_true
        order.items.loaded?.should be_true
        order.items.to_a.size.should eq 2
        order.items.each { |item| item.order_id.should eq order.id }
      end

      # Reading the loaded association does not query again.
      reread = capture_statements { orders.each(&.items.to_a) }
      reread.should be_empty
    end

    it "uses a row-value IN for the batch" do
      3_i64.times { |offset| make_order(1_i64, offset + 1).items.create!(sku: "s") }
      statements = capture_statements { CkAsOrder.includes(:items).to_a }
      items_sql = statements.find! { |sql| sql.starts_with?("SELECT") && sql.includes?("ck_as_items") }
      where_part(items_sql).should contain("IN")
      where_part(items_sql).should_not contain(" OR ")
    end

    it "keeps orders that share an order id apart" do
      seed_shared_ids
      orders = CkAsOrder.includes(:items).order(:shop_id).to_a
      orders.map { |order| order.items.to_a.map(&.sku.to_s).sort! }.should eq [["a1", "a2"], ["b1"]]
    end

    it "loads belongs_to with one query for all children" do
      seed_shared_ids
      items = [] of CkAsItem
      statements = capture_statements { items = CkAsItem.includes(:order).order(:sku).to_a }
      statements.select(&.starts_with?("SELECT")).size.should eq 2
      items.map { |item| item.order.not_nil!.shop_id }.should eq [1_i64, 1_i64, 2_i64]
    end

    it "loads has_one with one query" do
      order_one, order_two = seed_shared_ids
      CkAsReceipt.create!(shop_id: 1_i64, order_id: 5_i64, total: 10)
      CkAsReceipt.create!(shop_id: 2_i64, order_id: 5_i64, total: 20)
      orders = [] of CkAsOrder
      statements = capture_statements { orders = CkAsOrder.includes(:receipt).order(:shop_id).to_a }
      statements.select(&.starts_with?("SELECT")).size.should eq 2
      orders.map { |order| order.receipt.not_nil!.total }.should eq [10, 20]
    end

    it "preloads nested associations" do
      order_one, _ = seed_shared_ids
      CkAsReceipt.create!(shop_id: 1_i64, order_id: 5_i64, total: 10)
      orders = CkAsOrder.includes(items: :order).order(:shop_id).to_a
      orders.first.items.to_a.each { |item| item.association_loaded?(:order).should be_true }
    end

    it "runs one query per in_clause_limit tuples" do
      5_i64.times { |offset| make_order(1_i64, offset + 1).items.create!(sku: "s") }
      original = Grant.settings.in_clause_limit
      begin
        Grant.settings.in_clause_limit = 2
        statements = capture_statements { CkAsOrder.includes(:items).to_a }
        statements.select { |sql| sql.starts_with?("SELECT") && sql.includes?("ck_as_items") }.size.should eq 3
      ensure
        Grant.settings.in_clause_limit = original
      end
    end

    it "sets the inverse, so the child's parent is not queried again" do
      seed_shared_ids
      orders = CkAsOrder.includes(:items).to_a
      first_item = orders.first.items.to_a.first
      statements = capture_statements { first_item.order }
      statements.should be_empty
    end

    it "reload_items loads again with one batch query" do
      order, _ = seed_shared_ids
      order.items.to_a
      CkAsItem.create!(shop_id: 1_i64, order_id: 5_i64, sku: "a3")
      order.reload_items.size.should eq 3
    end
  end

  describe "joins" do
    it "joins on every key column pair" do
      seed_shared_ids
      make_order(3_i64, 5_i64)
      sql = CkAsOrder.joins(:items).to_sql
      sql.should contain("ck_as_items.shop_id")
      sql.should contain("ck_as_items.order_id")
      CkAsOrder.joins(:items).distinct.to_a.size.should eq 2

      CkAsItem.joins(:order).to_a.size.should eq 3
    end
  end

  describe "dependent" do
    it "destroy removes only the items of the whole tuple" do
      order_one, order_two = seed_shared_ids
      order_one.destroy.should be_true
      CkAsItem.count.should eq 1
      CkAsItem.first!.sku.should eq "b1"
      order_two.items.count.should eq 1
    end

    it "nullify clears the foreign key columns of the receipt" do
      order_one, _ = seed_shared_ids
      receipt = CkAsReceipt.create!(shop_id: 1_i64, order_id: 5_i64, total: 1)
      other = CkAsReceipt.create!(shop_id: 2_i64, order_id: 5_i64, total: 2)
      order_one.destroy
      receipt.reload
      receipt.shop_id.should be_nil
      receipt.order_id.should be_nil
      other.reload.shop_id.should eq 2_i64
    end
  end
end
