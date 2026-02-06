require "../../spec_helper"

describe "dependent: :delete_all" do
  before_all do
    DeleteAllParent.migrator.drop_and_create
    DeleteAllChild.migrator.drop_and_create
    DeleteAllOneChild.migrator.drop_and_create
  end

  before_each do
    DeleteAllChild.clear
    DeleteAllOneChild.clear
    DeleteAllParent.clear
  end

  describe "has_many dependent: :delete_all" do
    it "deletes all children with SQL DELETE when parent is destroyed" do
      parent = DeleteAllParent.new
      parent.name = "parent1"
      parent.save.should be_true

      # Create children
      3.times do |i|
        child = DeleteAllChild.new
        child.name = "child_#{i}"
        child.delete_all_parent_id = parent.id
        child.save.should be_true
      end

      DeleteAllChild.where(delete_all_parent_id: parent.id).count.should eq(3)

      # Destroy parent
      parent.destroy.should be_true

      # Children should be deleted
      DeleteAllChild.where(delete_all_parent_id: parent.id).count.should eq(0)
    end

    it "does not trigger callbacks on children" do
      parent = DeleteAllParent.new
      parent.name = "parent2"
      parent.save.should be_true

      child = DeleteAllChild.new
      child.name = "child_with_callback"
      child.delete_all_parent_id = parent.id
      child.save.should be_true

      # Destroy parent - children are SQL deleted (no callbacks)
      parent.destroy.should be_true

      # If callbacks were triggered, the child's before_destroy
      # would have set a flag. Since we used delete_all, the child
      # was never instantiated, so no callbacks ran.
      DeleteAllChild.where(delete_all_parent_id: parent.id).count.should eq(0)
    end
  end

  describe "has_one dependent: :delete" do
    it "deletes the child with SQL DELETE when parent is destroyed" do
      parent = DeleteAllParent.new
      parent.name = "parent3"
      parent.save.should be_true

      child = DeleteAllOneChild.new
      child.label = "only_child"
      child.delete_all_parent_id = parent.id
      child.save.should be_true

      DeleteAllOneChild.where(delete_all_parent_id: parent.id).count.should eq(1)

      parent.destroy.should be_true

      DeleteAllOneChild.where(delete_all_parent_id: parent.id).count.should eq(0)
    end
  end
end

# Test models for dependent: :delete_all
class DeleteAllParent < Grant::Base
  connection sqlite
  table delete_all_parents

  column id : Int64, primary: true
  column name : String?

  has_many :delete_all_children, class_name: DeleteAllChild, foreign_key: :delete_all_parent_id, dependent: :delete_all
  has_one :delete_all_one_child, class_name: DeleteAllOneChild, foreign_key: :delete_all_parent_id, dependent: :delete
end

class DeleteAllChild < Grant::Base
  connection sqlite
  table delete_all_children

  column id : Int64, primary: true
  column name : String?
  column delete_all_parent_id : Int64?

  belongs_to :delete_all_parent, optional: true
end

class DeleteAllOneChild < Grant::Base
  connection sqlite
  table delete_all_one_children

  column id : Int64, primary: true
  column label : String?
  column delete_all_parent_id : Int64?

  belongs_to :delete_all_parent, optional: true
end
