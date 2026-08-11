require "../../spec_helper"

describe "read_attribute" do
  # Only PG supports array types
  {% if env("CURRENT_ADAPTER") == "pg" %}
    it "able to read arrays" do
      ArrayModel.new.read_attribute("i32_array").should be_nil
    end
  {% end %}
end

describe "nil-safe column readers" do
  it "reads an unset non-nilable column without raising" do
    chat = Chat.new

    chat.name?.should be_nil
    expect_raises(NilAssertionError) { chat.name }
  end

  it "returns the assigned value" do
    chat = Chat.new
    chat.name = "Amber"

    chat.name?.should eq("Amber")
    chat.name.should eq("Amber")
  end

  it "also works for columns already declared nilable" do
    parent = Parent.new

    parent.name?.should be_nil
    parent.name = "Grant"
    parent.name?.should eq("Grant")
  end
end
