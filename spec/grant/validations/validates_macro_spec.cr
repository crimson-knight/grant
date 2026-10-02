require "../../spec_helper"
require "../../support/crystal_compiler"

class V01StrongPasswordValidator < Grant::EachValidator
  def validate_each(record, attribute, value)
    text = value.to_s
    unless text.size >= 8 && text.matches?(/\d/)
      record.errors.add(attribute, "is not strong enough", type: :weak)
    end
  end
end

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V01Unified < Grant::Base
    connection {{ adapter_literal }}
    table v01_unifieds

    column id : Int64, primary: true
    column name : String?
    column email : String?
    column password : String?
    column status : String?
    column code : String?
    column age : Int32?
    column nickname : String?
    column reason : String?
    column tos : String?

    validates :name, :email, presence: true, length: {min: 2, max: 40}
    validates :email, format: {with: /@/}, allow_nil: true
    validates :password, v01_strong_password: true, allow_nil: true
    validates :status, inclusion: %w[new open], allow_nil: true
    validates :code, length: 3, format: /\A[a-z]+\z/, allow_nil: true
    validates :age, numericality: {greater_than: 0, only_integer: true}, allow_nil: true
    validates :nickname, length: 2..5, allow_blank: true
    validates :reason, presence: true, on: [:publish], if: [:always?]
    validates :tos, acceptance: true, absence: false, allow_nil: true, strict: true, on: :create

    def always? : Bool
      true
    end
  end
{% end %}

private def unified : V01Unified
  record = V01Unified.new
  record.name = "Ada"
  record.email = "ada@example.com"
  record
end

describe "validates (unified macro)" do
  it "is valid for a well-formed record" do
    unified.valid?.should be_true
  end

  it "expands presence and length for several fields at once" do
    record = V01Unified.new
    record.valid?.should be_false
    record.errors.map(&.field.to_s).sort!.should eq(["email", "email", "name", "name"].sort)
    record.errors.map(&.type).uniq!.should contain(:blank)
    record.errors.map(&.message).should contain("can't be blank")
  end

  it "applies length options to each field" do
    record = unified
    record.name = "A"
    record.email = "@" * 41
    record.valid?.should be_false
    record.errors.map(&.field.to_s).sort!.should eq(["email", "name"])
    record.errors.map(&.message).uniq!.should eq(["is too short (minimum is 2 characters)", "is too long (maximum is 40 characters)"])
  end

  it "expands a format NamedTuple and passes shared allow_nil" do
    record = unified
    record.email = "nope"
    record.valid?.should be_false
    record.errors.map(&.type).should eq([:invalid])
  end

  it "resolves an unknown key to <Key>Validator" do
    record = unified
    record.password = "short"
    record.valid?.should be_false
    record.errors.first.type.should eq(:weak)
    record.password = "longenough1"
    record.valid?.should be_true
  end

  it "supports the shorthand forms (Array, Regex, Integer, Range)" do
    record = unified
    record.status = "closed"
    record.valid?.should be_false
    record.errors.first.type.should eq(:inclusion)

    record = unified
    record.code = "ab"
    record.valid?.should be_false
    record.errors.map(&.type).should eq([:wrong_length])

    record = unified
    record.code = "ab1"
    record.valid?.should be_false
    record.errors.map(&.type).should eq([:invalid])

    record = unified
    record.nickname = "a"
    record.valid?.should be_false
    record.nickname = "abcdef"
    record.valid?.should be_false
    record.nickname = ""
    record.valid?.should be_true
  end

  it "expands numericality options" do
    record = unified
    record.age = 0
    record.valid?.should be_false
    record.age = 3
    record.valid?.should be_true
  end

  it "shares on:, if: and strict: across the expanded validators" do
    record = unified
    record.valid?.should be_true
    record.valid?(:publish).should be_false
    record.errors.map(&.field.to_s).should eq(["reason"])
    record.reason = "why"
    record.valid?(:publish).should be_true

    record.tos = "no"
    expect_raises(Grant::StrictValidationFailed, /Tos must be accepted/) { record.valid? }
    record.valid?(:update).should be_true # on: :create only
  end

  it "treats `key: false` as disabled" do
    unified.valid?.should be_true
  end

  describe "compile errors" do
    repo_root = File.expand_path("../../..", __DIR__)

    compile = ->(body : String) do
      source = <<-CR
        require "sqlite3"
        require "../../../src/grant"
        require "../../../src/adapter/sqlite"

        class V01CompileCheck < Grant::Base
          connection sqlite
          table v01_compile_checks
          column id : Int64, primary: true
          column name : String?
        #{body}
        end
        CR
      # Written next to the spec so the relative requires above resolve.
      file = File.new(File.join(__DIR__, "v01_compile_check_#{Process.pid}.cr"), "w")
      file.print(source)
      file.close
      begin
        error = IO::Memory.new
        status = Process.run(spec_crystal_compiler, ["build", "--no-codegen", "--no-color", file.path], error: error, output: Process::Redirect::Close, chdir: repo_root)
        {status.success?, error.to_s}
      ensure
        file.delete
      end
    end

    it "rejects an unknown validator key" do
      ok, message = compile.call("  validates :name, bogus: true")
      ok.should be_false
      message.should contain("unknown key `bogus:`")
      message.should contain("BogusValidator")
    end

    it "rejects a stray message: option" do
      ok, message = compile.call("  validates :name, presence: true, message: \"x\"")
      ok.should be_false
      message.should contain("unknown key `message:`")
    end

    it "accepts a valid declaration" do
      ok, message = compile.call("  validates :name, presence: true, length: {maximum: 3}")
      ok.should be_true, message
    end
  end
end
