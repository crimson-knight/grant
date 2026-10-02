require "../../spec_helper"

class V01CustomStrictError < Exception
end

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V01StrictUser < Grant::Base
    connection {{ adapter_literal }}
    table v01_strict_users

    column id : Int64, primary: true
    column name : String?
    column email : String?
    column age : Int32?
    column code : String?
    column role : String?

    validates_presence_of :name, strict: true
    validates_length_of :email, maximum: 5, strict: true
    validates_numericality_of :age, greater_than: 0, allow_nil: true, strict: V01CustomStrictError
    validates_format_of :code, with: /\A\d+\z/, allow_nil: true, strict: true, on: :publish
    validates_inclusion_of :role, in: %w[a b], allow_nil: true
  end
{% end %}

private def strict_user : V01StrictUser
  user = V01StrictUser.new
  user.name = "Ada"
  user.email = "a@b.c"
  user
end

describe "strict: option" do
  it "does not raise for a valid record" do
    strict_user.valid?.should be_true
  end

  it "raises Grant::StrictValidationFailed with the full message instead of adding an error" do
    user = strict_user
    user.name = nil
    ex = expect_raises(Grant::StrictValidationFailed, "Name can't be blank") { user.valid? }
    ex.should be_a(Grant::ErrorBase)
    user.errors.empty?.should be_true
  end

  it "applies to every validates_*_of macro" do
    user = strict_user
    user.email = "too long for this"
    expect_raises(Grant::StrictValidationFailed, /Email is too long \(maximum is 5 characters\)/) { user.valid? }
  end

  it "raises a custom exception class when given one" do
    user = strict_user
    user.age = -1
    expect_raises(V01CustomStrictError, /Age must be greater than 0/) { user.valid? }
  end

  it "respects contexts" do
    user = strict_user
    user.code = "abc"
    user.valid?.should be_true
    expect_raises(Grant::StrictValidationFailed, /Code is invalid/) { user.valid?(:publish) }
  end

  it "raises from save and save! too, leaving the record unsaved" do
    user = strict_user
    user.name = nil
    expect_raises(Grant::StrictValidationFailed) { user.save }
    expect_raises(Grant::StrictValidationFailed) { user.save! }
    user.persisted?.should be_false
  end

  it "leaves non-strict validators adding errors" do
    user = strict_user
    user.role = "z"
    user.valid?.should be_false
    user.errors.map(&.field.to_s).should eq(["role"])
  end

  it "resets the validation context after raising" do
    user = strict_user
    user.name = nil
    expect_raises(Grant::StrictValidationFailed) { user.valid?(:publish) }
    user.validation_context.should be_nil
  end
end
