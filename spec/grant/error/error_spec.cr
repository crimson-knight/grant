require "../../spec_helper"

describe Grant::Error do
  it "should convert to json" do
    Grant::Error.new("field", "error message").to_json.should eq %({"field":"field","message":"error message"})
  end
end
