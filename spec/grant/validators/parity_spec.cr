require "../../spec_helper"

# =============================================================================
# Validation parity features:
#   - validate :method_name (bare Symbol)
#   - validates_with (reusable validator class) + validates_each
#   - validates_comparison_of / validates_absence_of
#   - invalid?
#   - errors.details (typed codes)
#   - Proc/lambda if:/unless: conditions on validations
# =============================================================================

# --- validate :method_name -------------------------------------------------
class MethodValidationModel < Grant::Base
  connection sqlite
  table method_validation_models

  column id : Int64, primary: true
  column total : Int32 = 0
  column discount : Int32 = 0

  validate :discount_within_total

  private def discount_within_total
    if discount > total
      errors.add(:discount, "cannot exceed total", type: :greater_than)
    end
  end
end

# bare-symbol validate scoped to a context + conditional
class MethodValidationContextModel < Grant::Base
  connection sqlite
  table method_validation_context_models

  column id : Int64, primary: true
  column flagged : Bool = false
  column run_check : Bool = true

  validate :must_not_be_flagged, on: :update, if: :run_check?

  def run_check?
    !!run_check
  end

  private def must_not_be_flagged
    errors.add(:base, "flagged", type: :invalid) if flagged
  end
end

# --- validates_with / EachValidator ----------------------------------------
class EvenValueValidator < Grant::Validator
  def validate(record)
    record = record.as(WithValidatorModel)
    if (v = record.value) && v.odd?
      record.errors.add(:value, "must be even", type: :even)
    end
  end
end

class ConfigurableValidator < Grant::Validator
  def initialize(@limit : Int32)
  end

  def validate(record)
    record = record.as(WithValidatorModel)
    if (v = record.value) && v > @limit
      record.errors.add(:value, "exceeds #{@limit}", type: :too_big)
    end
  end
end

class WithValidatorModel < Grant::Base
  connection sqlite
  table with_validator_models

  column id : Int64, primary: true
  column value : Int32?

  validates_with EvenValueValidator
  validates_with ConfigurableValidator, limit: 100
end

# EachValidator via validates_each
class PresenceEach < Grant::EachValidator
  def validate_each(record, attribute, value)
    if value.nil? || value.to_s.blank?
      record.errors.add(attribute, "can't be blank", type: :blank)
    end
  end
end

class EachValidatorModel < Grant::Base
  connection sqlite
  table each_validator_models

  column id : Int64, primary: true
  column name : String?
  column nickname : String?

  validates_each :name, :nickname, with: PresenceEach
end

# --- validates_comparison_of / validates_absence_of ------------------------
class ComparisonModel < Grant::Base
  connection sqlite
  table comparison_models

  column id : Int64, primary: true
  column age : Int32?
  column started_at : Int32?
  column ended_at : Int32?
  column status : String?

  validates_comparison_of :age, greater_than_or_equal_to: 18
  validates_comparison_of :ended_at, greater_than: :started_at, allow_nil: true
  validates_comparison_of :status, other_than: "archived", allow_nil: true
end

class AbsenceModel < Grant::Base
  connection sqlite
  table absence_models

  column id : Int64, primary: true
  column legacy_token : String?

  validates_absence_of :legacy_token
end

# --- Proc/lambda conditions ------------------------------------------------
class ProcConditionModel < Grant::Base
  connection sqlite
  table proc_condition_models

  column id : Int64, primary: true
  column kind : String = "draft"
  column reason : String?

  # Proc condition: only require reason when kind == "published"
  validates_presence_of :reason, if: ->(r : ProcConditionModel) { r.kind == "published" }
end

class ProcUnlessModel < Grant::Base
  connection sqlite
  table proc_unless_models

  column id : Int64, primary: true
  column skip : Bool = false
  column name : String?

  validates_presence_of :name, unless: ->(r : ProcUnlessModel) { !!r.skip }
end

describe "Validation parity" do
  describe "validate :method_name (bare Symbol)" do
    it "passes when the referenced method adds no errors" do
      m = MethodValidationModel.new
      m.total = 100
      m.discount = 10
      m.valid?.should be_true
    end

    it "fails when the referenced method adds an error" do
      m = MethodValidationModel.new
      m.total = 100
      m.discount = 150
      m.valid?.should be_false
      m.errors.map(&.field.to_s).should contain("discount")
      m.errors[:discount].should contain("cannot exceed total")
    end

    it "does not surface the placeholder :base entry when valid" do
      m = MethodValidationModel.new
      m.total = 100
      m.discount = 10
      m.valid?
      m.errors.size.should eq(0)
    end

    it "respects on: context (skips on create, runs on update)" do
      m = MethodValidationContextModel.new
      m.flagged = true
      m.valid?(context: :create).should be_true
      m.valid?(context: :update).should be_false
    end

    it "respects if: condition on bare-symbol validate" do
      m = MethodValidationContextModel.new
      m.flagged = true
      m.run_check = false
      m.valid?(context: :update).should be_true
    end
  end

  describe "validates_with (reusable validator class)" do
    it "passes when the validator records no errors" do
      m = WithValidatorModel.new
      m.value = 4
      m.valid?.should be_true
    end

    it "fails when the reusable validator records an error" do
      m = WithValidatorModel.new
      m.value = 3
      m.valid?.should be_false
      m.errors[:value].should contain("must be even")
    end

    it "forwards constructor arguments to a configurable validator" do
      m = WithValidatorModel.new
      m.value = 200 # even, but over limit 100
      m.valid?.should be_false
      m.errors[:value].should contain("exceeds 100")
    end

    it "passes both validators when value is even and under limit" do
      m = WithValidatorModel.new
      m.value = 50
      m.valid?.should be_true
    end
  end

  describe "validates_each (EachValidator)" do
    it "runs the each-validator per attribute and fails on blanks" do
      m = EachValidatorModel.new
      m.name = "set"
      m.nickname = nil
      m.valid?.should be_false
      m.errors.map(&.field.to_s).should contain("nickname")
      m.errors.map(&.field.to_s).should_not contain("name")
    end

    it "passes when all attributes are present" do
      m = EachValidatorModel.new
      m.name = "set"
      m.nickname = "nick"
      m.valid?.should be_true
    end
  end

  describe "validates_comparison_of" do
    it "passes when comparison holds" do
      m = ComparisonModel.new
      m.age = 21
      m.valid?.should be_true
    end

    it "fails when value is less than greater_than_or_equal_to operand" do
      m = ComparisonModel.new
      m.age = 17
      m.valid?.should be_false
      m.errors.map(&.field.to_s).should contain("age")
    end

    it "supports a Symbol operand naming another attribute" do
      m = ComparisonModel.new
      m.age = 21
      m.started_at = 10
      m.ended_at = 5 # ended before started -> invalid
      m.valid?.should be_false
      m.errors.map(&.field.to_s).should contain("ended_at")

      m.ended_at = 20 # after started -> valid
      m.valid?.should be_true
    end

    it "supports other_than with a literal" do
      m = ComparisonModel.new
      m.age = 21
      m.status = "archived"
      m.valid?.should be_false
      m.errors.map(&.field.to_s).should contain("status")

      m.status = "active"
      m.valid?.should be_true
    end
  end

  describe "validates_absence_of" do
    it "passes when the field is nil/blank" do
      m = AbsenceModel.new
      m.legacy_token = nil
      m.valid?.should be_true
      m.legacy_token = "   "
      m.valid?.should be_true
    end

    it "fails when the field is present" do
      m = AbsenceModel.new
      m.legacy_token = "leftover"
      m.valid?.should be_false
      m.errors[:legacy_token].should contain("must be blank")
    end
  end

  describe "#invalid?" do
    it "returns the inverse of valid?" do
      m = MethodValidationModel.new
      m.total = 100
      m.discount = 10
      m.invalid?.should be_false

      m.discount = 150
      m.invalid?.should be_true
    end

    it "honors the context argument" do
      m = MethodValidationContextModel.new
      m.flagged = true
      m.invalid?(context: :create).should be_false
      m.invalid?(context: :update).should be_true
    end
  end

  describe "errors.details (typed codes)" do
    it "exposes :blank for presence failures" do
      m = ProcConditionModel.new
      m.kind = "published"
      m.reason = nil
      m.valid?.should be_false
      m.errors.details["reason"].should eq([{:error => :blank}])
    end

    it "exposes the custom type passed to errors.add" do
      m = MethodValidationModel.new
      m.total = 100
      m.discount = 150
      m.valid?.should be_false
      m.errors.details["discount"].should eq([{:error => :greater_than}])
    end

    it "exposes :too_short for a minimum-length failure" do
      m = LengthDetailsModel.new
      m.code = "ab"
      m.valid?.should be_false
      m.errors.details["code"].should eq([{:error => :too_short}])
    end

    it "exposes :comparison for comparison failures" do
      m = ComparisonModel.new
      m.age = 5
      m.valid?.should be_false
      m.errors.details["age"].should eq([{:error => :comparison}])
    end

    it "falls back to :invalid when no type was provided" do
      e = Grant::Errors.new
      e.add(:name, "is weird")
      e.details["name"].should eq([{:error => :invalid}])
    end
  end

  describe "Proc/lambda if: conditions on validations" do
    it "gates the validation by the proc result (if:)" do
      m = ProcConditionModel.new
      m.kind = "draft"
      m.reason = nil
      m.valid?.should be_true # reason not required for draft

      m.kind = "published"
      m.valid?.should be_false # reason now required
      m.errors.map(&.field.to_s).should contain("reason")
    end

    it "gates the validation by the proc result (unless:)" do
      m = ProcUnlessModel.new
      m.skip = true
      m.name = nil
      m.valid?.should be_true # skipped

      m.skip = false
      m.valid?.should be_false
      m.errors.map(&.field.to_s).should contain("name")
    end
  end
end

class LengthDetailsModel < Grant::Base
  connection sqlite
  table length_details_models

  column id : Int64, primary: true
  column code : String?

  validates_length_of :code, minimum: 4
end
