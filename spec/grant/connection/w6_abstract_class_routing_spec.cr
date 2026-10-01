require "../../spec_helper"
require "../../support/w6_c04_support"

# Children are declared before the abstract parent says where they connect, so
# every query below proves the parent's declaration is read when it is used.
abstract class W6AppRecord < Grant::Base
  primary_abstract_class
end

class W6AbsEarlyThing < W6AppRecord
  table w6_abs_things
  column id : Int64, primary: true
  column label : String?
end

class W6AbsGrandThing < W6AbsEarlyThing
  table w6_abs_things
end

class W6AbsOwnThing < W6AppRecord
  table w6_abs_things
  column id : Int64, primary: true
  column label : String?
  connects_to database: {writing: "w6_abs_other", reading: "w6_abs_other_r"}
end

class W6AbsLateThing < W6AppRecord
  table w6_abs_things
  column id : Int64, primary: true
  column label : String?
end

class W6AbsUnrelatedThing < Grant::Base
  table w6_abs_things
  column id : Int64, primary: true
  column label : String?
  connects_to database: {writing: "w6_abs_other", reading: "w6_abs_other_r"}
end

abstract class W6AppRecord < Grant::Base
  connects_to(
    database: {writing: "w6_abs_main", reading: "w6_abs_main_r"},
    shards: {
      default: {writing: "w6_abs_main", reading: "w6_abs_main_r"},
      extra:   {writing: "w6_abs_extra"},
    }
  )
end

describe "abstract class connection routing (#{CURRENT_ADAPTER})" do
  before_all do
    ddl = ["CREATE TABLE w6_abs_things (#{W6C04.id_column}, label TEXT)"]
    {"w6_abs_main" => "main", "w6_abs_main_r" => "main replica", "w6_abs_other" => "other", "w6_abs_other_r" => "other replica", "w6_abs_extra" => "extra"}.each do |name, label|
      W6C04.provision(name, ddl)
      W6C04.exec(name, "INSERT INTO w6_abs_things (label) VALUES ('#{label}')")
      W6C04.establish(name, name, name.ends_with?("_r") ? :reading : :writing)
    end
  end

  after_all do
    %w(w6_abs_main w6_abs_main_r w6_abs_other w6_abs_other_r w6_abs_extra).each do |name|
      W6C04.remove(name, :writing)
      W6C04.remove(name, :reading)
    end
    W6C04.cleanup
  end

  it "routes every child to the parent's databases, whatever order they were declared in" do
    {% for model in %w(W6AbsEarlyThing W6AbsGrandThing W6AbsLateThing) %}
      {{model.id}}.connected_to(role: :writing) { {{model.id}}.first!.label }.should eq "main"
      {{model.id}}.connected_to(role: :reading) { {{model.id}}.first!.label }.should eq "main replica"
    {% end %}
  end

  it "writes through a child to the parent's writer, never its reader" do
    W6AbsGrandThing.create!(label: "from grandchild")

    W6C04.strings("w6_abs_main", "SELECT label FROM w6_abs_things ORDER BY id").should eq ["main", "from grandchild"]
    W6C04.strings("w6_abs_main_r", "SELECT label FROM w6_abs_things ORDER BY id").should eq ["main replica"]
    W6C04.exec("w6_abs_main", "DELETE FROM w6_abs_things WHERE label = 'from grandchild'")
  end

  it "lets a child's own connects_to replace the parent's whole declaration" do
    W6AbsOwnThing.connected_to(role: :writing) { W6AbsOwnThing.first!.label }.should eq "other"
    W6AbsOwnThing.connected_to(role: :reading) { W6AbsOwnThing.first!.label }.should eq "other replica"
    W6AbsOwnThing.shard_keys.should be_empty
    W6AbsOwnThing.sharded?.should be_false
    W6AbsEarlyThing.shard_keys.should eq [:default, :extra]
  end

  it "serves the parent's shards to its children" do
    W6AbsEarlyThing.connected_to(role: :writing, shard: :extra) { W6AbsEarlyThing.first!.label }.should eq "extra"
    W6AbsGrandThing.connected_to(role: :writing, shard: :default) { W6AbsGrandThing.first!.label }.should eq "main"
  end

  it "applies connected_to on the abstract parent to its children only" do
    W6AppRecord.connected_to(role: :reading) do
      W6AbsLateThing.first!.label.should eq "main replica"
      W6AbsGrandThing.first!.label.should eq "main replica"
      # The unrelated model keeps its own database, and is not switched.
      W6AbsUnrelatedThing.connection_context.should be_nil
      W6AbsUnrelatedThing.preventing_writes?.should be_false
    end
  end

  it "applies connected_to on Grant::Base to the children of the primary abstract class" do
    Grant::ConnectionHandling.primary_abstract_class_name.should eq "W6AppRecord"

    Grant::Base.connected_to(role: :reading) do
      W6AbsEarlyThing.first!.label.should eq "main replica"
      W6AbsOwnThing.first!.label.should eq "other replica"
      W6AbsUnrelatedThing.first!.label.should eq "other replica"
    end
  end

  it "follows a change made on the parent after a child resolved it" do
    original = W6AppRecord.connection_config
    begin
      W6AppRecord.connection_config = {:writing => "w6_abs_extra"}
      W6AbsLateThing.connected_to(role: :writing) { W6AbsLateThing.first!.label }.should eq "extra"
    ensure
      W6AppRecord.connection_config = original
    end
    W6AbsLateThing.connected_to(role: :writing) { W6AbsLateThing.first!.label }.should eq "main"
  end

  it "keeps the abstract marker on the parent alone" do
    W6AppRecord.abstract_class?.should be_true
    W6AbsEarlyThing.abstract_class?.should be_false
    W6AbsGrandThing.abstract_class?.should be_false
  end
end
