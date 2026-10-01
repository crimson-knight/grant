require "../../spec_helper"
require "../../support/composite_sql_recorder"

class CkLockedDoc < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table ck_locked_docs

  include Grant::Locking::Optimistic

  column id : Int64, primary: true
  column tenant_id : Int64
  column title : String?
  query_constraints :tenant_id, :id
end

describe "optimistic locking on a query_constraints model" do
  before_all do
    CkLockedDoc.migrator.drop_and_create
  end

  before_each do
    CkLockedDoc.clear
  end

  it "version-guarded update and destroy carry the constraint predicates" do
    doc = CkLockedDoc.create!(tenant_id: 1_i64, title: "a")
    doc.title = "b"
    update_sql = capture_statements { doc.save! }.select(&.starts_with?("UPDATE"))
    update_sql.size.should eq 1
    where_part(update_sql.first).should contain "tenant_id"

    destroy_sql = capture_statements { doc.destroy }.select(&.starts_with?("DELETE"))
    destroy_sql.size.should eq 1
    where_part(destroy_sql.first).should contain "tenant_id"
  end

  it "does not update a row of another tenant that shares the id" do
    doc = CkLockedDoc.create!(tenant_id: 1_i64, title: "a")
    doc.tenant_id = 2_i64
    doc.title = "moved"
    doc.save!
    CkLockedDoc.find({2_i64, doc.id.not_nil!}).not_nil!.title.should eq "moved"
  end
end
