require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  # Every validates_*_of macro takes several fields with one shared option set.
  class V01Multi < Grant::Base
    connection {{ adapter_literal }}
    table v01_multis

    column id : Int64, primary: true
    column first_name : String?
    column last_name : String?
    column age : Int32?
    column height : Int32?
    column email : String?
    column backup_email : String?
    column site : String?
    column blog : String?
    column start_no : Int32?
    column end_no : Int32?
    column role : String?
    column kind : String?
    column banned : String?
    column banned_too : String?
    column absent_a : String?
    column absent_b : String?
    column password : String?
    column pin : String?
    column tos : String?
    column eula : String?
    column code_a : String?
    column code_b : String?

    validates_presence_of :first_name, :last_name
    validates_length_of :first_name, :last_name, maximum: 5
    validates_size_of :code_a, :code_b, maximum: 3, allow_nil: true
    validates_numericality_of :age, :height, greater_than: 0, allow_nil: true
    validates_format_of :code_a, :code_b, with: /\A[a-z]+\z/, allow_nil: true
    validates_inclusion_of :role, :kind, in: %w[a b], allow_nil: true
    validates_exclusion_of :banned, :banned_too, in: %w[x], allow_nil: true
    validates_absence_of :absent_a, :absent_b
    validates_comparison_of :start_no, :end_no, greater_than: 0, allow_nil: true
    validates_confirmation_of :password, :pin
    validates_acceptance_of :tos, :eula, allow_nil: true
    validates_email :email, :backup_email, allow_nil: true
    validates_url :site, :blog, allow_nil: true
  end
{% end %}

private def multi : V01Multi
  record = V01Multi.new
  record.first_name = "Ada"
  record.last_name = "Byron"
  record
end

private def failing_fields(record : V01Multi) : Array(String)
  record.valid?
  record.errors.map(&.field.to_s).sort!
end

describe "multi-attribute validates_*_of" do
  it "is valid with sensible values" do
    multi.valid?.should be_true
  end

  it "validates_presence_of and validates_length_of check each field" do
    record = V01Multi.new
    failing_fields(record).should eq(["first_name", "last_name"])

    record = multi
    record.first_name = "Alexander"
    record.last_name = "Bartholomew"
    failing_fields(record).should eq(["first_name", "last_name"])
    record.errors.map(&.type).uniq!.should eq([:too_long])
  end

  it "validates_size_of, format, numericality" do
    record = multi
    record.code_a = "abcd"
    record.code_b = "AB"
    record.age = 0
    record.height = -2
    failing_fields(record).should eq(["age", "code_a", "code_b", "height"])
  end

  it "validates_inclusion_of and validates_exclusion_of" do
    record = multi
    record.role = "z"
    record.kind = "b"
    record.banned = "x"
    record.banned_too = "x"
    failing_fields(record).should eq(["banned", "banned_too", "role"])
  end

  it "validates_absence_of and validates_comparison_of" do
    record = multi
    record.absent_a = "x"
    record.absent_b = "y"
    record.start_no = 0
    record.end_no = 0
    failing_fields(record).should eq(["absent_a", "absent_b", "end_no", "start_no"])
  end

  it "validates_confirmation_of and validates_acceptance_of" do
    record = multi
    record.password = "p"
    record.password_confirmation = "q"
    record.pin = "1"
    record.pin_confirmation = "1"
    record.tos = "no"
    record.eula = "yes"
    failing_fields(record).should eq(["password", "tos"])
  end

  it "validates_email and validates_url" do
    record = multi
    record.email = "not an email"
    record.backup_email = "ok@example.com"
    record.site = "nope"
    record.blog = "https://example.com"
    failing_fields(record).should eq(["email", "site"])
  end

  it "applies message:, on: and if: to every field" do
    record = multi
    record.first_name = nil
    record.last_name = nil
    failing_fields(record).should eq(["first_name", "last_name"])
  end
end
