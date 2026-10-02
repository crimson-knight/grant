require "../../spec_helper"
require "../../support/w6_c04_support"

# A writer and a reader on two real databases (two SQLite files, or two
# PostgreSQL databases). The rows differ, so what a query returns names the
# database it reached.
class W6RoleHashThing < Grant::Base
  table w6_role_hash_things
  column id : Int64, primary: true
  column label : String?
  connects_to database: {writing: "w6_rh_primary", reading: "w6_rh_replica"}
end

class W6RoleHashOtherThing < Grant::Base
  table w6_role_hash_other_things
  column id : Int64, primary: true
  column label : String?
  connects_to database: {writing: "w6_rh_primary", reading: "w6_rh_replica"}
end

describe "connected_to(database: {role => connection}) on #{CURRENT_ADAPTER}" do
  before_all do
    ddl = ["CREATE TABLE w6_role_hash_things (#{W6C04.id_column}, label TEXT)",
           "CREATE TABLE w6_role_hash_other_things (#{W6C04.id_column}, label TEXT)"]
    W6C04.provision("w6_rh_primary", ddl)
    W6C04.provision("w6_rh_replica", ddl)
    W6C04.exec("w6_rh_primary", "INSERT INTO w6_role_hash_things (label) VALUES ('primary row')")
    W6C04.exec("w6_rh_replica", "INSERT INTO w6_role_hash_things (label) VALUES ('replica row')")
    W6C04.exec("w6_rh_primary", "INSERT INTO w6_role_hash_other_things (label) VALUES ('other primary row')")
    W6C04.exec("w6_rh_replica", "INSERT INTO w6_role_hash_other_things (label) VALUES ('other replica row')")
    W6C04.establish("w6_rh_primary", "w6_rh_primary", :writing)
    W6C04.establish("w6_rh_replica", "w6_rh_replica", :reading)
  end

  after_all do
    W6C04.remove("w6_rh_primary", :writing)
    W6C04.remove("w6_rh_replica", :reading)
    W6C04.cleanup
  end

  it "uses the only role of the hash and its connection" do
    W6RoleHashThing.connected_to(database: {reading: "w6_rh_replica"}) do
      W6RoleHashThing.current_role.should eq :reading
      W6RoleHashThing.current_database.should eq "w6_rh_replica"
      W6RoleHashThing.first!.label
    end.should eq "replica row"

    W6RoleHashThing.connected_to(database: {writing: "w6_rh_primary"}) { W6RoleHashThing.first!.label }.should eq "primary row"
  end

  it "prevents writes in the reading role and leaves both databases alone" do
    expect_raises(Grant::Transaction::ReadOnlyError) do
      W6RoleHashThing.connected_to(database: {reading: "w6_rh_replica"}) { W6RoleHashThing.create!(label: "refused") }
    end

    W6C04.strings("w6_rh_primary", "SELECT label FROM w6_role_hash_things ORDER BY id").should eq ["primary row"]
    W6C04.strings("w6_rh_replica", "SELECT label FROM w6_role_hash_things ORDER BY id").should eq ["replica row"]
  end

  it "writes to the connection of a writing role" do
    W6RoleHashThing.connected_to(database: {writing: "w6_rh_primary"}) { W6RoleHashThing.create!(label: "written") }

    W6C04.strings("w6_rh_primary", "SELECT label FROM w6_role_hash_things ORDER BY id").should contain "written"
    W6C04.strings("w6_rh_replica", "SELECT label FROM w6_role_hash_things ORDER BY id").should eq ["replica row"]
  end

  it "picks the connection of role: when the hash names several roles" do
    roles = {writing: "w6_rh_primary", reading: "w6_rh_replica"}

    W6RoleHashThing.connected_to(database: roles, role: :reading) { W6RoleHashThing.first!.label }.should eq "replica row"
    W6RoleHashThing.connected_to(database: roles, role: :writing) { W6RoleHashThing.first!.label }.should eq "primary row"
  end

  it "needs role: when the hash names several roles, and a role the hash has" do
    roles = {writing: "w6_rh_primary", reading: "w6_rh_replica"}

    expect_raises(ArgumentError, /needs role:/) { W6RoleHashThing.connected_to(database: roles) { } }
    expect_raises(ArgumentError, /no connection for role :other/) { W6RoleHashThing.connected_to(database: roles, role: :other) { } }
  end

  it "accepts a Hash of role to connection name" do
    roles = {:reading => "w6_rh_replica"}

    W6RoleHashThing.connected_to(database: roles) { W6RoleHashThing.first!.label }.should eq "replica row"
  end

  it "lets the hash override what the model declared, for the block only" do
    W6RoleHashThing.connected_to(database: {reading: "w6_rh_primary"}) { W6RoleHashThing.first!.label }.should eq "primary row"
    W6RoleHashThing.connected_to(role: :reading) { W6RoleHashThing.first!.label }.should eq "replica row"
  end

  it "answers connected_to? for the role and restores the previous context" do
    W6RoleHashThing.connected_to(database: {reading: "w6_rh_replica"}) do
      W6RoleHashThing.connected_to?(role: :reading).should be_true
    end
    W6RoleHashThing.connected_to?(role: :reading).should be_false
    W6RoleHashThing.current_database.should eq "w6_rh_primary"
  end

  it "sizes the pool of each role on its own connection" do
    yaml = <<-YAML
      test:
        w6_rhp:
          url: #{W6C04.url("w6_rh_primary")}
          pool: 5
        w6_rhp_replica:
          url: #{W6C04.url("w6_rh_replica")}
          pool: 2
          replica: true
      YAML
    Grant::DatabaseConfigurations.parse(yaml, "test", ->(_key : String) { nil.as(String?) }).establish_connections

    begin
      writer = Grant::ConnectionRegistry.get_adapter("w6_rhp", :writing)
      reader = Grant::ConnectionRegistry.get_adapter("w6_rhp", :reading)
      Grant::ConnectionRegistry.connection_spec("w6_rhp", :writing).not_nil!.pool_size.should eq 5
      Grant::ConnectionRegistry.connection_spec("w6_rhp", :reading).not_nil!.pool_size.should eq 2
      writer.open(&.scalar("SELECT 1"))
      reader.open(&.scalar("SELECT 1"))
      writer.pool_stat.size.should eq 5
      reader.pool_stat.size.should eq 2
    ensure
      W6C04.remove("w6_rhp", :writing)
      W6C04.remove("w6_rhp", :reading)
    end
  end

  it "switches several models at once with connected_to_many" do
    labels = Grant.connected_to_many(W6RoleHashThing, W6RoleHashOtherThing, role: :reading) do
      {W6RoleHashThing.first!.label, W6RoleHashOtherThing.first!.label}
    end

    labels.should eq({"replica row", "other replica row"})
  end
end
