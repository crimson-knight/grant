require "../../spec_helper"
require "../../support/composite_sql_recorder"

class CkPersistItem < Grant::Base
  include Grant::CompositePrimaryKey

  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table ck_persist_items

  column shop_id : Int64, primary: true, auto: false
  column order_id : Int64, primary: true, auto: false
  column quantity : Int32?
  column note : String?
  column views : Int32?
  composite_primary_key shop_id, order_id

  timestamps
end

class CkPersistSession < Grant::Base
  include Grant::CompositePrimaryKey

  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table ck_persist_sessions

  column user_id : Int64, primary: true, auto: false
  column session_id : UUID, primary: true
  column agent : String?
  composite_primary_key user_id, session_id
end

describe "composite primary key persistence" do
  before_all do
    CkPersistItem.migrator.drop_and_create
    CkPersistSession.migrator.drop_and_create
  end

  before_each do
    CkPersistItem.clear
    CkPersistSession.clear
  end

  describe "create" do
    it "inserts a row carrying every key column and reads it back" do
      item = CkPersistItem.new(shop_id: 1_i64, order_id: 10_i64, quantity: 3)
      item.new_record?.should be_true
      item.save.should be_true
      item.new_record?.should be_false
      item.persisted?.should be_true

      found = CkPersistItem.find({1_i64, 10_i64}).not_nil!
      found.shop_id.should eq 1_i64
      found.order_id.should eq 10_i64
      found.quantity.should eq 3
      CkPersistItem.count.should eq 1
    end

    it "create and create! return persisted records" do
      CkPersistItem.create(shop_id: 1_i64, order_id: 11_i64, quantity: 1).persisted?.should be_true
      CkPersistItem.create!(shop_id: 1_i64, order_id: 12_i64, quantity: 2).persisted?.should be_true
      CkPersistItem.count.should eq 2
    end

    it "rejects a second row with the same key tuple" do
      CkPersistItem.create!(shop_id: 2_i64, order_id: 1_i64, quantity: 1)
      duplicate = CkPersistItem.new(shop_id: 2_i64, order_id: 1_i64, quantity: 9)
      duplicate.save.should be_false
      CkPersistItem.count.should eq 1
      CkPersistItem.find!({2_i64, 1_i64}).quantity.should eq 1
    end

    it "accepts the same first key part with another second part" do
      CkPersistItem.create!(shop_id: 2_i64, order_id: 1_i64)
      CkPersistItem.create!(shop_id: 2_i64, order_id: 2_i64)
      CkPersistItem.count.should eq 2
    end

    it "refuses a record whose key part is unset" do
      item = CkPersistItem.new(shop_id: 3_i64, quantity: 1)
      item.save.should be_false
      CkPersistItem.count.should eq 0
    end

    it "generates an auto UUID key part" do
      session = CkPersistSession.new(user_id: 7_i64, agent: "curl")
      session.save.should be_true, session.errors.map(&.to_s).join(", ")
      session.session_id.should_not be_nil
      found = CkPersistSession.find({7_i64, session.session_id.not_nil!}).not_nil!
      found.agent.should eq "curl"
    end
  end

  describe "update" do
    it "changes only the row with the full key tuple and carries both predicates" do
      first = CkPersistItem.create!(shop_id: 1_i64, order_id: 1_i64, quantity: 1)
      sibling = CkPersistItem.create!(shop_id: 1_i64, order_id: 2_i64, quantity: 1)
      other_shop = CkPersistItem.create!(shop_id: 2_i64, order_id: 1_i64, quantity: 1)

      statements = capture_statements do
        first.quantity = 50
        first.save.should be_true
      end

      updates = statements.select(&.starts_with?("UPDATE"))
      updates.size.should eq 1
      where_part(updates.first).should contain("shop_id")
      where_part(updates.first).should contain("order_id")

      CkPersistItem.find!({1_i64, 1_i64}).quantity.should eq 50
      CkPersistItem.find!({1_i64, 2_i64}).quantity.should eq 1
      CkPersistItem.find!({2_i64, 1_i64}).quantity.should eq 1
      sibling.reload.quantity.should eq 1
      other_shop.reload.quantity.should eq 1
    end

    it "update(**args) and update! work" do
      item = CkPersistItem.create!(shop_id: 1_i64, order_id: 1_i64, quantity: 1)
      item.update(quantity: 7, note: "a").should be_true
      item.update!(quantity: 8).should be_true
      reloaded = CkPersistItem.find!({1_i64, 1_i64})
      reloaded.quantity.should eq 8
      reloaded.note.should eq "a"
    end

    it "touch bumps updated_at on its own row only, with both predicates" do
      item = CkPersistItem.create!(shop_id: 1_i64, order_id: 1_i64, quantity: 1)
      other = CkPersistItem.create!(shop_id: 1_i64, order_id: 2_i64, quantity: 1)
      other_stamp = CkPersistItem.find!({1_i64, 2_i64}).updated_at

      statements = capture_statements { item.touch.should be_true }
      update = statements.find(&.starts_with?("UPDATE")).not_nil!
      where_part(update).should contain("shop_id")
      where_part(update).should contain("order_id")
      CkPersistItem.find!({1_i64, 2_i64}).updated_at.should eq other_stamp
    end

    it "update_columns and increment! address the row by its whole key" do
      item = CkPersistItem.create!(shop_id: 1_i64, order_id: 1_i64, quantity: 1, views: 0)
      other = CkPersistItem.create!(shop_id: 1_i64, order_id: 2_i64, quantity: 1, views: 0)

      statements = capture_statements do
        item.update_columns(note: "direct").should be_true
        item.increment!(:views, 5)
      end
      statements.select(&.starts_with?("UPDATE")).each do |update|
        where_part(update).should contain("shop_id")
        where_part(update).should contain("order_id")
      end

      CkPersistItem.find!({1_i64, 1_i64}).views.should eq 5
      CkPersistItem.find!({1_i64, 1_i64}).note.should eq "direct"
      CkPersistItem.find!({1_i64, 2_i64}).views.should eq 0
      other.reload.note.should be_nil
    end
  end

  describe "destroy and delete" do
    it "destroy removes only its own row and carries both predicates" do
      item = CkPersistItem.create!(shop_id: 1_i64, order_id: 1_i64)
      CkPersistItem.create!(shop_id: 1_i64, order_id: 2_i64)
      CkPersistItem.create!(shop_id: 2_i64, order_id: 1_i64)

      statements = capture_statements { item.destroy.should be_true }
      delete = statements.find(&.starts_with?("DELETE")).not_nil!
      where_part(delete).should contain("shop_id")
      where_part(delete).should contain("order_id")

      item.destroyed?.should be_true
      CkPersistItem.count.should eq 2
      CkPersistItem.find({1_i64, 1_i64}).should be_nil
    end

    it "delete removes only its own row" do
      item = CkPersistItem.create!(shop_id: 1_i64, order_id: 1_i64)
      CkPersistItem.create!(shop_id: 1_i64, order_id: 2_i64)
      item.delete
      item.destroyed?.should be_true
      CkPersistItem.count.should eq 1
      CkPersistItem.exists?({1_i64, 2_i64}).should be_true
    end
  end

  describe "reload" do
    it "round trips: reload picks up a change made elsewhere, SELECT carries both predicates" do
      item = CkPersistItem.create!(shop_id: 1_i64, order_id: 1_i64, quantity: 1)
      CkPersistItem.create!(shop_id: 1_i64, order_id: 2_i64, quantity: 2)
      CkPersistItem.where(shop_id: 1_i64, order_id: 1_i64).update_all(quantity: 99)

      statements = capture_statements { item.reload }
      read_sql = statements.find(&.starts_with?("SELECT")).not_nil!
      where_part(read_sql).should contain("shop_id")
      where_part(read_sql).should contain("order_id")

      item.quantity.should eq 99
      item.changed?.should be_false
    end

    it "raises NotFound when the row is gone" do
      item = CkPersistItem.create!(shop_id: 1_i64, order_id: 1_i64)
      CkPersistItem.where(shop_id: 1_i64, order_id: 1_i64).delete_all
      expect_raises(Grant::Querying::NotFound) { item.reload }
    end
  end

  describe "key helpers" do
    it "exposes the key as values, to_key and to_param" do
      item = CkPersistItem.create!(shop_id: 4_i64, order_id: 5_i64)
      item.key_tuple_values.should eq [4_i64, 5_i64]
      item.to_key.should eq [4_i64, 5_i64]
      item.id.should eq [4_i64, 5_i64]
      CkPersistItem.new(shop_id: 1_i64).id.should be_nil
      item.to_param.should eq "4-5"
      CkPersistItem.persistence_key_columns.should eq ["shop_id", "order_id"]
    end
  end
end
