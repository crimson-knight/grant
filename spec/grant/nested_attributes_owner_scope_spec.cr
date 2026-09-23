require "./luna_t4_spec_helper"

class NestedAttributesOwnerScopeChild < Grant::Base
  connection {{ env("CURRENT_ADAPTER").id }}
  table nested_attributes_owner_scope_children

  column id : Int64, primary: true
  column parent_id : Int64?
  column tenant_id : Int64
  column label : String

  multitenant :tenant_id
end

class NestedAttributesOwnerScopeParent < Grant::Base
  connection {{ env("CURRENT_ADAPTER").id }}
  table nested_attributes_owner_scope_parents

  column id : Int64, primary: true
  column tenant_id : Int64
  column label : String

  has_many :children, class_name: NestedAttributesOwnerScopeChild, foreign_key: :parent_id
  accepts_nested_attributes_for children : NestedAttributesOwnerScopeChild, allow_destroy: true
  enable_nested_saves

  multitenant :tenant_id
end

describe "Grant::NestedAttributes owner scoping" do
  before_each do
    GrantLunaT4SpecHelper.ensure_test_connection
    NestedAttributesOwnerScopeChild.migrator.drop_and_create
    NestedAttributesOwnerScopeParent.migrator.drop_and_create
  end

  it "rejects update and destroy IDs outside the owner association" do
    Grant::Tenant.with(1_i64) do
      parent_a = NestedAttributesOwnerScopeParent.create!(label: "parent A")
      parent_b = NestedAttributesOwnerScopeParent.create!(label: "parent B")
      update_target = NestedAttributesOwnerScopeChild.create!(parent_id: parent_b.id, label: "private")
      destroy_target = NestedAttributesOwnerScopeChild.create!(parent_id: parent_b.id, label: "also private")

      parent_a.children_attributes = [{id: update_target.id, label: "changed by A"}]
      parent_a.save.should be_true
      NestedAttributesOwnerScopeChild.find!(update_target.id).label.should eq("private")

      parent_a.children_attributes = [{id: destroy_target.id, _destroy: true}]
      parent_a.save.should be_true
      NestedAttributesOwnerScopeChild.find(destroy_target.id).should_not be_nil
      parent_a.errors.any? { |error| error.field.to_s == "children" }.should be_true
    end
  end

  it "does not resolve nested IDs hidden by the target tenant scope" do
    target_id = nil.as(Int64?)

    Grant::Tenant.with(1_i64) do
      parent = NestedAttributesOwnerScopeParent.create!(label: "tenant one")

      NestedAttributesOwnerScopeChild.unscoped do
        target = NestedAttributesOwnerScopeChild.create!(parent_id: parent.id, tenant_id: 2_i64, label: "tenant two")
        target_id = target.id
      end

      parent.children_attributes = [{id: target_id.not_nil!, label: "changed across tenants"}]
      parent.save.should be_true
    end

    NestedAttributesOwnerScopeChild.unscoped do
      NestedAttributesOwnerScopeChild.find!(target_id.not_nil!).label.should eq("tenant two")
    end
  end
end
