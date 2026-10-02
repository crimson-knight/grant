require "../../spec_helper"
require "../../support/composite_sql_recorder"

class CkTenantDoc < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table ck_tenant_docs

  column id : Int64, primary: true
  column tenant_id : Int64
  column title : String?
  column views : Int32?
  query_constraints :tenant_id, :id

  timestamps
end

class CkPlainDoc < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table ck_plain_docs

  column id : Int64, primary: true
  column title : String?
  column views : Int32?
  timestamps
end

# Every persistence statement must name both constraint columns in its WHERE.
private def carries_constraints?(sql : String) : Bool
  predicate = where_part(sql)
  predicate.includes?("tenant_id") && predicate.matches?(/(?<![A-Za-z_])id(?![A-Za-z_])/)
end

private def writes(statements : Array(String)) : Array(String)
  statements.select { |sql| sql.starts_with?("UPDATE") || sql.starts_with?("DELETE") }
end

describe "query_constraints" do
  before_all do
    CkTenantDoc.migrator.drop_and_create
    CkPlainDoc.migrator.drop_and_create
  end

  before_each do
    CkTenantDoc.clear
    CkPlainDoc.clear
  end

  it "declares the constraint columns" do
    CkTenantDoc.query_constrained?.should be_true
    CkTenantDoc.persistence_key_columns.should eq ["tenant_id", "id"]
    CkTenantDoc.primary_name.should eq "id"
    CkTenantDoc.composite_primary_key?.should be_false
    CkPlainDoc.responds_to?(:query_constrained?).should be_false
  end

  describe "find" do
    it "finds by the constraint tuple only inside the tenant" do
      doc = CkTenantDoc.create!(tenant_id: 1_i64, title: "mine")
      CkTenantDoc.find({1_i64, doc.id.not_nil!}).not_nil!.title.should eq "mine"
      CkTenantDoc.find({2_i64, doc.id.not_nil!}).should be_nil
      CkTenantDoc.find({tenant_id: 1_i64, id: doc.id.not_nil!}).should_not be_nil
      CkTenantDoc.exists?({2_i64, doc.id.not_nil!}).should be_false
      expect_raises(Grant::Querying::NotFound) { CkTenantDoc.find!({2_i64, doc.id.not_nil!}) }
    end

    it "carries both predicates in the SELECT" do
      doc = CkTenantDoc.create!(tenant_id: 1_i64, title: "mine")
      statements = capture_statements { CkTenantDoc.find({1_i64, doc.id.not_nil!}) }
      statements.select(&.starts_with?("SELECT")).each { |sql| carries_constraints?(sql).should be_true }
    end
  end

  describe "update" do
    it "writes WHERE tenant_id = ? AND id = ?" do
      doc = CkTenantDoc.create!(tenant_id: 1_i64, title: "old")
      statements = capture_statements { doc.update(title: "new").should be_true }
      writes(statements).size.should eq 1
      writes(statements).each { |sql| carries_constraints?(sql).should be_true }
      CkTenantDoc.find!({1_i64, doc.id.not_nil!}).title.should eq "new"
    end

    it "does not touch a row that moved to another tenant" do
      doc = CkTenantDoc.create!(tenant_id: 1_i64, title: "old")
      CkTenantDoc.where(id: doc.id).update_all(tenant_id: 2_i64)

      doc.update(title: "stolen").should be_true
      CkTenantDoc.find!({2_i64, doc.id.not_nil!}).title.should eq "old"
    end

    it "moves a row when the constraint column itself changes, addressing it by its stored key" do
      doc = CkTenantDoc.create!(tenant_id: 1_i64, title: "moving")
      doc.tenant_id = 5_i64
      doc.save.should be_true
      CkTenantDoc.find({1_i64, doc.id.not_nil!}).should be_nil
      CkTenantDoc.find({5_i64, doc.id.not_nil!}).not_nil!.title.should eq "moving"
    end
  end

  describe "destroy and delete" do
    it "destroy carries both predicates" do
      doc = CkTenantDoc.create!(tenant_id: 1_i64, title: "x")
      statements = capture_statements { doc.destroy.should be_true }
      writes(statements).size.should eq 1
      writes(statements).each { |sql| carries_constraints?(sql).should be_true }
      CkTenantDoc.count.should eq 0
    end

    it "destroy leaves a row of another tenant alone" do
      doc = CkTenantDoc.create!(tenant_id: 1_i64, title: "x")
      CkTenantDoc.where(id: doc.id).update_all(tenant_id: 2_i64)
      doc.destroy
      CkTenantDoc.count.should eq 1
    end

    it "delete carries both predicates and spares another tenant" do
      doc = CkTenantDoc.create!(tenant_id: 1_i64, title: "x")
      other = CkTenantDoc.create!(tenant_id: 1_i64, title: "y")
      statements = capture_statements { doc.delete }
      writes(statements).each { |sql| carries_constraints?(sql).should be_true }
      CkTenantDoc.exists?({1_i64, other.id.not_nil!}).should be_true

      CkTenantDoc.where(id: other.id).update_all(tenant_id: 3_i64)
      other.delete
      CkTenantDoc.count.should eq 1
    end
  end

  describe "reload" do
    it "selects by the whole constraint tuple" do
      doc = CkTenantDoc.create!(tenant_id: 1_i64, title: "old")
      CkTenantDoc.where(id: doc.id).update_all(title: "changed")
      statements = capture_statements { doc.reload }
      statements.select(&.starts_with?("SELECT")).each { |sql| carries_constraints?(sql).should be_true }
      doc.title.should eq "changed"
    end

    it "raises NotFound when the row now belongs to another tenant" do
      doc = CkTenantDoc.create!(tenant_id: 1_i64, title: "old")
      CkTenantDoc.where(id: doc.id).update_all(tenant_id: 2_i64)
      expect_raises(Grant::Querying::NotFound) { doc.reload }
    end
  end

  describe "touch, update_columns and increment!" do
    it "touch carries both predicates and spares another tenant's row" do
      doc = CkTenantDoc.create!(tenant_id: 1_i64, title: "x")
      statements = capture_statements { doc.touch.should be_true }
      writes(statements).size.should eq 1
      writes(statements).each { |sql| carries_constraints?(sql).should be_true }

      CkTenantDoc.where(id: doc.id).update_all(tenant_id: 2_i64)
      stamp = CkTenantDoc.find!({2_i64, doc.id.not_nil!}).updated_at
      sleep 1100.milliseconds
      doc.touch
      CkTenantDoc.find!({2_i64, doc.id.not_nil!}).updated_at.should eq stamp
    end

    it "update_columns carries both predicates" do
      doc = CkTenantDoc.create!(tenant_id: 1_i64, title: "x")
      statements = capture_statements { doc.update_columns(title: "direct") }
      writes(statements).size.should eq 1
      writes(statements).each { |sql| carries_constraints?(sql).should be_true }

      CkTenantDoc.where(id: doc.id).update_all(tenant_id: 2_i64)
      doc.update_columns(title: "lost")
      CkTenantDoc.find!({2_i64, doc.id.not_nil!}).title.should eq "direct"
    end

    it "increment! carries both predicates and spares another tenant's row" do
      doc = CkTenantDoc.create!(tenant_id: 1_i64, title: "x", views: 0)
      statements = capture_statements { doc.increment!(:views, 3) }
      writes(statements).size.should eq 1
      writes(statements).each { |sql| carries_constraints?(sql).should be_true }
      CkTenantDoc.find!({1_i64, doc.id.not_nil!}).views.should eq 3

      CkTenantDoc.where(id: doc.id).update_all(tenant_id: 2_i64)
      doc.increment!(:views, 10)
      CkTenantDoc.find!({2_i64, doc.id.not_nil!}).views.should eq 3
    end
  end

  describe "models without query_constraints" do
    it "keep writing WHERE id = ? only" do
      doc = CkPlainDoc.create!(title: "plain", views: 0)
      statements = capture_statements do
        doc.update(title: "p2")
        doc.touch
        doc.increment!(:views)
        doc.reload
        doc.destroy
      end
      statements.each { |sql| where_part(sql).should_not contain("tenant_id") }
      CkPlainDoc.count.should eq 0
    end
  end
end
