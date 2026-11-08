require "spec"

{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "spec"
require "../../../../../../src/grant/drivers/pg/pq/param"

private def it_encodes_array(value, encoded)
  it "encodes #{value.class}" do
    Grant::PQ::Param.encode_array(value).should eq encoded
  end
end

describe Grant::PQ::Param do
  describe "encoders" do
    describe "#encode_array" do
      it_encodes_array([] of String, "{}")
      it_encodes_array([true, false, true], "{t,f,t}")
      it_encodes_array(["t", "f", "t"], %({"t","f","t"}))
      it_encodes_array([1, 2, 3], "{1,2,3}")
      it_encodes_array([1.2, 3.4, 5.6], "{1.2,3.4,5.6}")
      it_encodes_array([%(a), %(\\b~), %(c\\"d), %(\uFF8F)], %({"a","\\\\b~","c\\\\\\"d","\uFF8F"}))
      it_encodes_array([%(this is a "slice").to_slice], %({"\\\\x7468697320697320612022736c69636522"}))
      it_encodes_array(["baz, bar"], %({"baz, bar"}))
      it_encodes_array(["foo}"], %({"foo}"}))
      it_encodes_array([nil, nil], %({NULL,NULL}))
    end
  end
end
