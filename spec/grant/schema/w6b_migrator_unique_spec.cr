require "../../support/test_connection"

class W6bUqUser < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_uq_users

  column id : Int64, primary: true
  column email : String?
  column handle : String?
  column org_id : Int64?

  validates_uniqueness_of :email, constraint: true
  validates_uniqueness_of :handle, scope: [:org_id], constraint: {name: "uniq_w6b_handle_in_org"}
end

class W6bUqPlain < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_uq_plains

  column id : Int64, primary: true
  column email : String?

  validates_uniqueness_of :email
end

class W6bUqOrg < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_uq_orgs

  column id : Int64, primary: true
end

class W6bUqScoped < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_uq_scoped

  column id : Int64, primary: true
  column code : String?
  belongs_to w6b_uq_org, optional: true

  validates_uniqueness_of :code, scope: :w6b_uq_org, constraint: true
end

describe "Migrator UNIQUE from validates_uniqueness_of on #{CURRENT_ADAPTER}" do
  quote = CURRENT_ADAPTER == "mysql" ? "`" : "\""

  before_each do
    TestConnection.ensure_registered
    W6bUqUser.migrator.drop_and_create
    W6bUqPlain.migrator.drop_and_create
    W6bUqOrg.migrator.drop_and_create
    W6bUqScoped.migrator.drop_and_create
  end

  after_all do
    W6bUqUser.migrator.drop
    W6bUqPlain.migrator.drop
    W6bUqScoped.migrator.drop
    W6bUqOrg.migrator.drop
  end

  it "emits UNIQUE for a field, a scoped field and an association scope" do
    sql = W6bUqUser.migrator.create_sql
    sql.should contain "CONSTRAINT #{quote}uniq_w6b_uq_users_email#{quote} UNIQUE (#{quote}email#{quote})"
    sql.should contain "CONSTRAINT #{quote}uniq_w6b_handle_in_org#{quote} UNIQUE (#{quote}handle#{quote}, #{quote}org_id#{quote})"
    W6bUqScoped.migrator.create_sql.should contain "UNIQUE (#{quote}code#{quote}, #{quote}w6b_uq_org_id#{quote})"
  end

  it "emits nothing without constraint:" do
    W6bUqPlain.migrator.create_sql.should_not contain "UNIQUE"
  end

  it "reads the constraints back from the database" do
    constraints = W6bUqUser.adapter.schema.unique_constraints(:w6b_uq_users).map(&.columns)
    constraints.should contain ["email"]
    constraints.should contain ["handle", "org_id"]
  end

  it "rejects a duplicate the validation was skipped for, with a Grant error" do
    W6bUqUser.create!(email: "a@example.com", handle: "a", org_id: 1_i64)
    W6bUqUser.new(email: "a@example.com").valid?.should be_false
    expect_raises(Grant::ErrorBase) { W6bUqUser.new(email: "a@example.com").save!(validate: false) }
    # the same handle in another organization is fine, in the same one it is not
    W6bUqUser.create!(email: "b@example.com", handle: "a", org_id: 2_i64)
    expect_raises(Grant::ErrorBase) { W6bUqUser.new(email: "c@example.com", handle: "a", org_id: 1_i64).save!(validate: false) }
  end

  it "lets rows with a NULL column repeat, as the validation does" do
    W6bUqUser.create!(email: nil)
    W6bUqUser.create!(email: nil)
    W6bUqUser.count.should eq 2
  end

  it "resolves the association scope to its foreign key column" do
    W6bUqScoped.create!(code: "x", w6b_uq_org_id: 1_i64)
    W6bUqScoped.create!(code: "x", w6b_uq_org_id: 2_i64)
    expect_raises(Grant::ErrorBase) { W6bUqScoped.new(code: "x", w6b_uq_org_id: 1_i64).save!(validate: false) }
  end
end
