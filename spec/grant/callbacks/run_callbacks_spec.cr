require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class RunCallbacksModel < Grant::Base
    connection {{ adapter_literal }}
    table run_callbacks_models

    column id : Int64, primary: true
    column name : String?

    property log : Array(String) = [] of String
    property gate : Bool = true

    before_save { log << "before_save" }
    after_save { log << "after_save" }
    after_touch { log << "after_touch" }
    before_destroy { log << "before_destroy" }
    after_destroy { log << "after_destroy" }

    around_save :maybe_gate

    def wrap_save(&block : -> Int32) : Int32?
      run_callbacks(:save) { block.call }
    end

    def wrap_destroy(&block : -> Nil)
      run_callbacks(:destroy) { block.call }
    end

    def bare_touch : Bool
      run_callbacks(:touch)
    end

    private def maybe_gate(block : Proc(Nil))
      log << "around_in"
      block.call if gate
      log << "around_out"
    end
  end
{% end %}

describe "run_callbacks" do
  before_all do
    RunCallbacksModel.migrator.drop_and_create
  end

  it "runs the block between the before and after chains inside the around chain" do
    record = RunCallbacksModel.new(name: "a")
    result = record.wrap_save do
      record.log << "block"
      42
    end

    result.should eq(42)
    record.log.should eq(["around_in", "before_save", "block", "after_save", "around_out"])
  end

  it "returns nil and skips the block and after chain when an around callback halts" do
    record = RunCallbacksModel.new(name: "a")
    record.gate = false
    ran = false
    result = record.wrap_save do
      ran = true
      42
    end

    result.should be_nil
    ran.should be_false
    record.around_halted?.should be_true
    record.log.should eq(["around_in", "around_out"])
  end

  it "runs events that have no around chain around the block" do
    record = RunCallbacksModel.new(name: "a")
    record.wrap_destroy { record.log << "block" }
    record.log.should eq(["before_destroy", "block", "after_destroy"])
  end

  it "runs a bare event chain with no block" do
    record = RunCallbacksModel.new(name: "a")
    record.bare_touch.should be_true
    record.log.should eq(["after_touch"])
  end

  it "propagates abort! raised in a callback" do
    record = RunCallbacksModel.new(name: "a")
    expect_raises(Grant::Callbacks::Abort) do
      record.wrap_save { record.abort!("stop"); 1 }
    end
  end

  it "dispatches a runtime symbol through a case statement" do
    record = RunCallbacksModel.new(name: "a")
    event = :save
    record.run_callbacks_for(event).should be_true
    record.log.should eq(["around_in", "before_save", "after_save", "around_out"])

    record.log.clear
    record.gate = false
    record.run_callbacks_for(event).should be_false

    expect_raises(ArgumentError, /Unknown callback event/) do
      record.run_callbacks_for(:bogus)
    end
  end
end
