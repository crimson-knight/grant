require "../../spec_helper"

class ScopingBlockWidget < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table scoping_block_widgets

  column id : Int64, primary: true
  column name : String?
  column color : String?
end

class ScopingBlockGadget < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table scoping_block_gadgets

  column id : Int64, primary: true
  column color : String?
  column deleted : Bool = false

  default_scope { where(deleted: false) }
end

describe "Model.scoping { }" do
  before_each do
    ScopingBlockWidget.migrator.drop_and_create
    ScopingBlockGadget.migrator.drop_and_create
    ScopingBlockWidget.create(name: "a", color: "red")
    ScopingBlockWidget.create(name: "b", color: "red")
    ScopingBlockWidget.create(name: "c", color: "blue")
    ScopingBlockGadget.create(color: "red")
    ScopingBlockGadget.create(color: "red", deleted: true)
  end

  it "makes the relation the current scope for class-level queries" do
    ScopingBlockWidget.scoping(ScopingBlockWidget.where(color: "red")) do
      ScopingBlockWidget.count.should eq 2
      ScopingBlockWidget.all.map(&.name.to_s).sort!.should eq ["a", "b"]
      ScopingBlockWidget.where(name: "c").to_a.should be_empty
      ScopingBlockWidget.where(name: "a").first.not_nil!.color.should eq "red"
    end
    ScopingBlockWidget.count.should eq 3
  end

  it "is available on a relation" do
    ScopingBlockWidget.where(color: "blue").scoping do
      ScopingBlockWidget.count.should eq 1
      ScopingBlockWidget.first.not_nil!.name.should eq "c"
    end
  end

  it "returns the block's value" do
    value = ScopingBlockWidget.scoping(ScopingBlockWidget.where(color: "red")) { ScopingBlockWidget.count }
    value.should eq 2
  end

  it "nests and restores each level" do
    ScopingBlockWidget.scoping(ScopingBlockWidget.where(color: "red")) do
      ScopingBlockWidget.scoping(ScopingBlockWidget.unscoped.where(color: "blue")) do
        ScopingBlockWidget.count.should eq 1
      end
      ScopingBlockWidget.count.should eq 2
    end
    ScopingBlockWidget.count.should eq 3
  end

  it "restores the previous scope when the block raises" do
    expect_raises(Exception, "boom") do
      ScopingBlockWidget.scoping(ScopingBlockWidget.where(color: "red")) do
        ScopingBlockWidget.count.should eq 2
        raise "boom"
      end
    end
    ScopingBlockWidget.count.should eq 3
    Fiber.current.grant_scoping_stacks.should be_nil
  end

  it "is local to the fiber that opened the block" do
    seen_in_other_fiber = Channel(Int64).new
    ScopingBlockWidget.scoping(ScopingBlockWidget.where(color: "red")) do
      spawn { seen_in_other_fiber.send(ScopingBlockWidget.count) }
      seen_in_other_fiber.receive.should eq 3
      ScopingBlockWidget.count.should eq 2
    end
  end

  it "is ignored by unscoped and does not touch other models" do
    ScopingBlockWidget.scoping(ScopingBlockWidget.where(color: "red")) do
      ScopingBlockWidget.unscoped.count.should eq 3
      ScopingBlockGadget.count.should eq 1
    end
  end

  it "is hidden inside the block form of unscoped, as ActiveRecord's" do
    ScopingBlockWidget.scoping(ScopingBlockWidget.where(color: "red")) do
      ScopingBlockWidget.unscoped { |_| ScopingBlockWidget.count }.should eq 3
      ScopingBlockWidget.unscoped do |_|
        ScopingBlockWidget.scoping(ScopingBlockWidget.unscoped.where(color: "blue")) do
          ScopingBlockWidget.count.should eq 1
        end
      end
      ScopingBlockWidget.count.should eq 2
    end
    Fiber.current.grant_scoping_stacks.should be_nil
  end

  it "keeps the default scope of a relation built from the model" do
    ScopingBlockGadget.scoping(ScopingBlockGadget.where(color: "red")) do
      ScopingBlockGadget.count.should eq 1
    end
    ScopingBlockGadget.scoping(ScopingBlockGadget.unscoped.where(color: "red")) do
      ScopingBlockGadget.count.should eq 2
    end
    ScopingBlockGadget.count.should eq 1
  end

  it "reaches async queries started inside the block" do
    result = ScopingBlockWidget.scoping(ScopingBlockWidget.where(color: "red")) do
      ScopingBlockWidget.async_count
    end
    result.wait.should eq 2
  end
end
