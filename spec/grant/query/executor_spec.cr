require "../../spec_helper"

describe Grant::Query::Executor::List do
  before_each do
    Parent.clear
  end

  it "runs a list query and hydrates its records" do
    parent = Parent.create!(name: "Executor parent")
    executor = Parent.where(name: "Executor parent").assembler.select

    executor.should be_a(Grant::Query::Executor::List(Parent))
    records = executor.run

    records.size.should eq(1)
    records.first.id.should eq(parent.id)
    records.first.name.should eq("Executor parent")
  end
end
