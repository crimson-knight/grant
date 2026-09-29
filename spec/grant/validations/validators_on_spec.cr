require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V02vPerson < Grant::Base
    connection {{ adapter_literal }}
    table v02v_people

    column id : Int64, primary: true
    column name : String?
    column email : String?
    column age : Int32?
    column role : String?

    validates_presence_of :name
    validates_length_of :name, minimum: 2, maximum: 40
    validates_format_of :email, with: /@/, allow_nil: true
    validates_numericality_of :age, greater_than_or_equal_to: 0, only_integer: true, on: :create
    validates_inclusion_of :role, in: ["admin", "user"], if: :check_role?
    validates_uniqueness_of :email, scope: [:role]
    validate :some_rule
    validate "generic failure" { |person| true }
    validates_each :name do |record, attribute, value|
    end

    def check_role?
      true
    end

    private def some_rule
    end
  end

  class V02vEmployee < V02vPerson
    validates_presence_of :role
  end
{% end %}

describe "validator reflection" do
  it "lists the validators on an attribute in declaration order" do
    V02vPerson.validators_on(:name).map(&.kind).should eq([:presence, :length, :each])
    V02vPerson.validators_on("name").size.should eq(3)
  end

  it "reports the options a validator was declared with" do
    length = V02vPerson.validators_on(:name)[1]
    length.attribute.should eq("name")
    length.option(:minimum).should eq(2)
    length.option(:maximum).should eq(40)
    length.options.keys.should eq([:minimum, :maximum])
  end

  it "reports allow_nil, contexts and conditions" do
    email = V02vPerson.validators_on(:email).first
    email.kind.should eq(:format)
    email.option(:allow_nil).should eq(true)
    email.contexts.should eq([:save])
    email.conditional?.should be_false

    age = V02vPerson.validators_on(:age).first
    age.contexts.should eq([:create])
    age.options.keys.should eq([:greater_than_or_equal_to, :only_integer])

    role = V02vPerson.validators_on(:role).first
    role.kind.should eq(:inclusion)
    role.conditional?.should be_true
    role.option(:in).should eq(["admin", "user"])
  end

  it "reports uniqueness scopes as data" do
    uniqueness = V02vPerson.validators_on(:email).find { |info| info.kind == :uniqueness }.not_nil!
    uniqueness.option(:scope).should eq(["role"])
  end

  it "answers required? for a plain presence validator" do
    V02vPerson.validators_on(:name).first.required?.should be_true
    V02vPerson.validators_on(:email).first.required?.should be_false
  end

  it "includes several attributes and the validators of ancestors" do
    V02vPerson.validators_on(:email, :age).size.should eq(3)
    V02vEmployee.validators_on(:name).map(&.kind).should eq([:presence, :length, :each])
    V02vEmployee.validators_on(:role).map(&.kind).should eq([:inclusion, :presence])
    V02vPerson.validators_on(:role).map(&.kind).should eq([:inclusion])
  end

  it "introspects validate callbacks by kind" do
    V02vPerson.validators.map(&.kind).should contain(:method)
    V02vPerson.validators.map(&.kind).should contain(:custom)
    V02vPerson.validators.select { |info| info.kind == :method }.first.attribute.should eq("base")
  end

  it "returns nothing for an attribute without validators" do
    V02vPerson.validators_on(:id).should be_empty
  end

  it "does not change validation behavior" do
    person = V02vPerson.new(name: "a")
    person.valid?.should be_false
    person.errors.full_messages.should contain("Name must be at least 2 characters and at most 40 characters")
  end
end
