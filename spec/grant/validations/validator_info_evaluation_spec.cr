require "../../spec_helper"

# Counts how many times the inclusion list below is computed, to prove that
# reflection does not evaluate a validator's option expressions at class load.
module V02ReflectionEvaluationCounter
  class_property calls_to_allowed_roles = 0
end

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V02rAccount < Grant::Base
    connection {{ adapter_literal }}
    table v02r_accounts

    column id : Int64, primary: true
    column role : String?
    column score : Int32?

    ROLE_NAMES   = ["owner", "member"]
    BANNED_NAMES = ["banned"]

    validates_inclusion_of :role, in: V02rAccount.allowed_roles
    validates_exclusion_of :role, in: BANNED_NAMES + ["root"]
    validates_numericality_of :score, in: 1..10, allow_nil: true

    def self.allowed_roles : Array(String)
      V02ReflectionEvaluationCounter.calls_to_allowed_roles += 1
      ROLE_NAMES
    end
  end
{% end %}

describe "validator reflection of option expressions" do
  it "records a method call option as its source text without calling it" do
    V02ReflectionEvaluationCounter.calls_to_allowed_roles = 0
    inclusion = V02rAccount.validators_on(:role).find! { |info| info.kind == :inclusion }
    inclusion.option(:in).should eq("V02rAccount.allowed_roles")
    V02ReflectionEvaluationCounter.calls_to_allowed_roles.should eq(0)
  end

  it "records any other non-literal expression as its source text" do
    exclusion = V02rAccount.validators_on(:role).find! { |info| info.kind == :exclusion }
    exclusion.option(:in).should eq(%(BANNED_NAMES + ["root"]))
  end

  it "keeps literal ranges as data" do
    numericality = V02rAccount.validators_on(:score).first
    numericality.option(:in).should eq(1..10)
  end

  it "still evaluates the option on every validation" do
    V02ReflectionEvaluationCounter.calls_to_allowed_roles = 0
    V02rAccount.new(role: "owner").valid?.should be_true
    V02rAccount.new(role: "guest").valid?.should be_false
    V02ReflectionEvaluationCounter.calls_to_allowed_roles.should eq(2)
  end
end
