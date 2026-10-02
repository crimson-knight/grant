require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class PrependCallbackModel < Grant::Base
    connection {{ adapter_literal }}
    table prepend_callback_models

    column id : Int64, primary: true
    column name : String?

    property log : Array(String) = [] of String

    before_save { log << "first" }
    before_save :second
    before_save :prepended_a, :prepended_b, prepend: true
    before_save(prepend: true) { log << "block_prepended" }
    around_save :around_inner
    around_save :around_outer, prepend: true

    private def second
      log << "second"
    end

    private def prepended_a
      log << "prepended_a"
    end

    private def prepended_b
      log << "prepended_b"
    end

    private def around_inner(block : Proc(Nil))
      log << "inner_in"
      block.call
    end

    private def around_outer(block : Proc(Nil))
      log << "outer_in"
      block.call
    end
  end
{% end %}

describe "callback prepend: true" do
  before_all do
    PrependCallbackModel.migrator.drop_and_create
  end

  it "runs prepended before callbacks first, keeping their given order" do
    record = PrependCallbackModel.new(name: "a")
    record.before_save
    record.log.should eq(["block_prepended", "prepended_a", "prepended_b", "first", "second"])
  end

  it "makes a prepended around callback outermost" do
    record = PrependCallbackModel.new(name: "a")
    record.save.should be_true
    record.log.select(&.ends_with?("_in")).should eq(["outer_in", "inner_in"])
  end
end
