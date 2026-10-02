require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V01Conditional < Grant::Base
    connection {{ adapter_literal }}
    table v01_conditionals

    column id : Int64, primary: true
    column name : String?
    column plan : String?
    column active : Bool = true
    column admin : Bool = false
    column trial : Bool = false

    property log = [] of String

    def active? : Bool
      !!active
    end

    def admin? : Bool
      !!admin
    end

    def trial? : Bool
      !!trial
    end

    # Both terms must hold.
    validates_presence_of :name, if: [:active?, ->(r : V01Conditional) { r.plan == "pro" }]
    # Skipped when any unless: term holds.
    validates_length_of :name, minimum: 3, allow_nil: true, unless: [:admin?, ->(r : V01Conditional) { r.trial? }]
    # Combined if: and unless: lists.
    validates_inclusion_of :plan, in: %w[pro free], if: [:active?], unless: [:admin?]
    # validate :method with arrays
    validate :must_not_be_reserved, if: [:active?, ->(r : V01Conditional) { !r.name.nil? }], unless: [:admin?]

    before_validation :log_before, if: [:active?, ->(r : V01Conditional) { r.plan == "pro" }]
    after_validation :log_after, if: :active?, unless: [:admin?, ->(r : V01Conditional) { r.trial? }]
    before_save :log_save, if: [:active?], unless: [:trial?]

    private def must_not_be_reserved
      errors.add(:name, "is reserved") if name == "root"
    end

    private def log_before
      log << "before"
    end

    private def log_after
      log << "after"
    end

    private def log_save
      log << "save"
    end
  end
{% end %}

Spec.before_suite do
  V01Conditional.migrator.drop_and_create
end

private def conditional(name : String? = "Ada", plan : String? = "pro", active : Bool = true, admin : Bool = false, trial : Bool = false) : V01Conditional
  record = V01Conditional.new
  record.name = name
  record.plan = plan
  record.active = active
  record.admin = admin
  record.trial = trial
  record
end

describe "condition arrays" do
  describe "if: with several terms (ANDed)" do
    it "validates when every term holds" do
      record = conditional(name: nil)
      record.valid?.should be_false
      record.errors.map(&.field.to_s).should contain("name")
    end

    it "skips when the Symbol term is false" do
      record = conditional(name: nil, active: false, plan: nil)
      record.valid?.should be_true
    end

    it "skips when the Proc term is false" do
      record = conditional(name: nil, plan: "free")
      record.errors.clear
      record.valid?.should be_true
    end
  end

  describe "unless: with several terms (any skips)" do
    it "validates when no term holds" do
      conditional(name: "Al").valid?.should be_false
    end

    it "skips when the Symbol term holds" do
      conditional(name: "Al", admin: true).valid?.should be_true
    end

    it "skips when the Proc term holds" do
      conditional(name: "Al", trial: true).valid?.should be_true
    end
  end

  describe "combined if: and unless: lists" do
    it "requires every if: term and no unless: term" do
      conditional(plan: "gold").valid?.should be_false
      conditional(plan: "gold", admin: true).valid?.should be_true
      conditional(plan: "gold", active: false).valid?.should be_true
    end
  end

  describe "validate :method with arrays" do
    it "runs when the conditions hold" do
      record = conditional(name: "root")
      record.valid?.should be_false
      record.errors.map(&.to_s).should contain("Name is reserved")
    end

    it "is skipped by unless:" do
      conditional(name: "root", admin: true).valid?.should be_true
    end
  end

  describe "callbacks" do
    it "run only when every if: term holds and no unless: term does" do
      record = conditional
      record.valid?
      record.log.should eq(["before", "after"])

      record = conditional(plan: "free")
      record.valid?
      record.log.should eq(["after"])

      record = conditional(admin: true)
      record.valid?
      record.log.should eq(["before"])

      record = conditional(trial: true)
      record.valid?
      record.log.should eq(["before"])
    end

    it "supports single-element arrays on save callbacks" do
      record = conditional
      record.save.should be_true
      record.log.should contain("save")

      record = conditional(trial: true)
      record.save.should be_true
      record.log.should_not contain("save")
    end
  end
end
