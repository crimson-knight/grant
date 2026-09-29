require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class DsOwner < Grant::Base
    connection {{ adapter_literal }}
    table ds_owners
    column id : Int64, primary: true
    column name : String?
    has_many :ds_plain, class_name: DsChild, foreign_key: :ds_owner_id
    has_many :ds_nullified, class_name: DsChild, foreign_key: :ds_owner_id, dependent: :nullify
    has_many :ds_deleted, class_name: DsChild, foreign_key: :ds_owner_id, dependent: :delete_all
    has_many :ds_destroyed, class_name: DsChild, foreign_key: :ds_owner_id, dependent: :destroy
  end

  class DsChild < Grant::Base
    connection {{ adapter_literal }}
    table ds_children
    column id : Int64, primary: true
    column ds_owner_id : Int64?
    column note : String?

    @@destroyed_count = 0

    def self.destroyed_count : Int32
      @@destroyed_count
    end

    def self.reset_destroyed_count : Nil
      @@destroyed_count = 0
    end

    after_destroy do
      @@destroyed_count += 1
    end
  end
{% end %}

private def children_of(owner : DsOwner)
  DsChild.where(ds_owner_id: owner.id).count
end

describe "collection delete, delete_all and destroy strategies" do
  before_all do
    DsOwner.migrator.drop_and_create
    DsChild.migrator.drop_and_create
  end

  before_each do
    DsChild.clear
    DsOwner.clear
    DsChild.reset_destroyed_count
  end

  describe "delete" do
    it "nullifies the foreign key with one UPDATE by default" do
      owner = DsOwner.create!(name: "o")
      kept = DsChild.create!(ds_owner_id: owner.id, note: "n")
      other = DsChild.create!(ds_owner_id: owner.id, note: "n")

      removed = [] of DsChild
      statements = StatementRecorder.statements { removed = owner.ds_plain.delete(other) }

      removed.map(&.id).should eq([other.id])
      StatementRecorder.count(statements, "UPDATE", "ds_children").should eq(1)
      StatementRecorder.count(statements, "DELETE").should eq(0)
      DsChild.find!(other.id).ds_owner_id.should be_nil
      DsChild.find!(kept.id).ds_owner_id.should eq(owner.id)
    end

    it "removes several records with one UPDATE" do
      owner = DsOwner.create!(name: "o")
      children = 3.times.map { DsChild.create!(ds_owner_id: owner.id, note: "n") }.to_a

      statements = StatementRecorder.statements { owner.ds_plain.delete(children[0], children[1], children[2]) }

      StatementRecorder.count(statements, "UPDATE", "ds_children").should eq(1)
      children_of(owner).should eq(0)
    end

    it "ignores a record that is not in the collection" do
      owner = DsOwner.create!(name: "o")
      other_owner = DsOwner.create!(name: "o")
      stranger = DsChild.create!(ds_owner_id: other_owner.id, note: "n")

      owner.ds_plain.delete(stranger).should be_empty

      DsChild.find!(stranger.id).ds_owner_id.should eq(other_owner.id)
    end

    it "deletes the rows for dependent: :delete_all" do
      owner = DsOwner.create!(name: "o")
      child = DsChild.create!(ds_owner_id: owner.id, note: "n")

      owner.ds_deleted.delete(child)

      DsChild.find(child.id).should be_nil
      DsChild.destroyed_count.should eq(0)
    end

    it "destroys the records with callbacks for dependent: :destroy" do
      owner = DsOwner.create!(name: "o")
      child = DsChild.create!(ds_owner_id: owner.id, note: "n")

      owner.ds_destroyed.delete(child)

      DsChild.find(child.id).should be_nil
      DsChild.destroyed_count.should eq(1)
    end
  end

  describe "delete_all" do
    it "nullifies with one UPDATE when no dependent option is set" do
      owner = DsOwner.create!(name: "o")
      3.times { DsChild.create!(ds_owner_id: owner.id, note: "n") }

      count = 0_i64
      statements = StatementRecorder.statements { count = owner.ds_plain.delete_all }

      count.should eq(3)
      StatementRecorder.count(statements, "UPDATE", "ds_children").should eq(1)
      StatementRecorder.count(statements, "SELECT").should eq(0)
      DsChild.count.should eq(3)
      children_of(owner).should eq(0)
    end

    it "follows dependent: :nullify" do
      owner = DsOwner.create!(name: "o")
      DsChild.create!(ds_owner_id: owner.id, note: "n")

      owner.ds_nullified.delete_all.should eq(1)

      DsChild.count.should eq(1)
      children_of(owner).should eq(0)
    end

    it "deletes with one DELETE for dependent: :delete_all" do
      owner = DsOwner.create!(name: "o")
      2.times { DsChild.create!(ds_owner_id: owner.id, note: "n") }

      statements = StatementRecorder.statements { owner.ds_deleted.delete_all.should eq(2) }

      StatementRecorder.count(statements, "DELETE FROM").should eq(1)
      DsChild.count.should eq(0)
    end

    it "destroys each record for dependent: :destroy" do
      owner = DsOwner.create!(name: "o")
      2.times { DsChild.create!(ds_owner_id: owner.id, note: "n") }

      owner.ds_destroyed.delete_all.should eq(2)

      DsChild.count.should eq(0)
      DsChild.destroyed_count.should eq(2)
    end

    it "lets the argument override the association's strategy" do
      owner = DsOwner.create!(name: "o")
      2.times { DsChild.create!(ds_owner_id: owner.id, note: "n") }

      owner.ds_plain.delete_all(:delete_all).should eq(2)
      DsChild.count.should eq(0)

      2.times { DsChild.create!(ds_owner_id: owner.id, note: "n") }
      owner.ds_plain.delete_all(:destroy).should eq(2)
      DsChild.destroyed_count.should eq(2)

      2.times { DsChild.create!(ds_owner_id: owner.id, note: "n") }
      owner.ds_deleted.delete_all(:nullify).should eq(2)
      DsChild.count.should eq(2)
    end

    it "rejects an unknown strategy" do
      owner = DsOwner.create!(name: "o")

      expect_raises(ArgumentError, /Unknown dependent strategy/) { owner.ds_plain.delete_all(:bogus) }
    end

    it "empties a loaded collection" do
      owner = DsOwner.create!(name: "o")
      DsChild.create!(ds_owner_id: owner.id, note: "n")
      collection = owner.ds_plain
      collection.load_target.size.should eq(1)

      collection.delete_all

      collection.to_a.should be_empty
    end
  end

  describe "clear" do
    it "nullifies by default and deletes for dependent: :delete_all" do
      owner = DsOwner.create!(name: "o")
      DsChild.create!(ds_owner_id: owner.id, note: "n")
      owner.ds_plain.clear
      DsChild.count.should eq(1)
      children_of(owner).should eq(0)

      DsChild.create!(ds_owner_id: owner.id, note: "n")
      owner.ds_deleted.clear
      DsChild.count.should eq(1)
    end
  end

  describe "destroy and destroy_all" do
    it "destroy_all returns the destroyed records and runs callbacks" do
      owner = DsOwner.create!(name: "o")
      2.times { DsChild.create!(ds_owner_id: owner.id, note: "n") }

      destroyed = owner.ds_plain.destroy_all

      destroyed.size.should eq(2)
      destroyed.all?(&.destroyed?).should be_true
      DsChild.count.should eq(0)
      DsChild.destroyed_count.should eq(2)
    end

    it "destroy removes only the given records" do
      owner = DsOwner.create!(name: "o")
      gone = DsChild.create!(ds_owner_id: owner.id, note: "n")
      kept = DsChild.create!(ds_owner_id: owner.id, note: "n")

      owner.ds_plain.destroy(gone).map(&.id).should eq([gone.id])

      DsChild.find(gone.id).should be_nil
      DsChild.find(kept.id).should_not be_nil
    end
  end
end
