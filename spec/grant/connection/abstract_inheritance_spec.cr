require "../../spec_helper"

# Declared in the order that matters: children exist before the parent's
# connects_to runs.
abstract class C01AbstractRecord < Grant::Base
  abstract_class
end

class C01EarlyChild < C01AbstractRecord
  table c01_early_children
  column id : Int64, primary: true
end

class C01GrandChild < C01EarlyChild
end

class C01OverridingChild < C01AbstractRecord
  table c01_overriding_children
  column id : Int64, primary: true
  connects_to database: {writing: "c01_own_writer", reading: "c01_own_reader"}
end

class C01LateChild < C01AbstractRecord
  table c01_late_children
  column id : Int64, primary: true
end

abstract class C01PrimaryAbstract < Grant::Base
  primary_abstract_class
end

# Reopened after every child above was declared.
abstract class C01AbstractRecord < Grant::Base
  connects_to(
    database: {writing: "c01_abs_writer", reading: "c01_abs_reader"},
    shards: {
      default: {writing: "c01_abs_writer", reading: "c01_abs_reader"},
      two:     {writing: "c01_abs_two", reading: "c01_abs_two_reader"},
    }
  )
end

describe "abstract class connection inheritance" do
  it "propagates a later connects_to on the parent to earlier and later children" do
    {C01EarlyChild.default_database_name, C01LateChild.default_database_name, C01GrandChild.default_database_name}
      .should eq({"c01_abs_writer", "c01_abs_writer", "c01_abs_writer"})
    C01EarlyChild.connection_config.should eq({:writing => "c01_abs_writer", :reading => "c01_abs_reader"})
    C01GrandChild.connection_config[:reading].should eq "c01_abs_reader"
    C01LateChild.shard_keys.should eq [:default, :two]
    C01GrandChild.sharded?.should be_true
  end

  it "lets a child's own connects_to win over the parent's" do
    C01OverridingChild.default_database_name.should eq "c01_own_writer"
    C01OverridingChild.connection_config[:reading].should eq "c01_own_reader"
    # connects_to replaces only what it names; the parent's shards still apply.
    C01OverridingChild.shard_keys.should eq [:default, :two]

    C01EarlyChild.default_database_name.should eq "c01_abs_writer"
  end

  it "follows a change made on the parent after children resolved it" do
    original = C01AbstractRecord.connection_config
    begin
      C01AbstractRecord.connection_config = {:writing => "c01_moved", :reading => "c01_moved_reader"}
      C01GrandChild.connection_config[:writing].should eq "c01_moved"
    ensure
      C01AbstractRecord.connection_config = original
    end
    C01GrandChild.connection_config[:writing].should eq "c01_abs_writer"
  end

  it "does not let one model's connects_to reach its siblings" do
    C01OverridingChild.default_database_name.should_not eq C01LateChild.default_database_name
  end

  it "marks abstract classes without inheriting the marker" do
    C01AbstractRecord.abstract_class?.should be_true
    C01EarlyChild.abstract_class?.should be_false
    C01GrandChild.abstract_class?.should be_false
    Todo.abstract_class?.should be_false
  end

  it "records the primary abstract class" do
    C01PrimaryAbstract.abstract_class?.should be_true
    Grant::ConnectionHandling.primary_abstract_class_name.should eq "C01PrimaryAbstract"
  end

  it "applies connected_to on the abstract parent to its children only" do
    C01AbstractRecord.connected_to(role: :reading) do
      C01GrandChild.connected_to?(role: :reading).should be_true
      C01GrandChild.preventing_writes?.should be_true
      Todo.connected_to?(role: :reading).should be_false
    end
  end
end
