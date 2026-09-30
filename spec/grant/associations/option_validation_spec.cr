require "../../spec_helper"

# Association options are checked while the macro expands, so a typo fails the
# build instead of being ignored. Each case compiles a small program with
# `--no-codegen` and reads the compiler's error.
#
# The compile runs inside the slot this spec already holds (the spec binary is
# idle while it waits), so it does not add a concurrent compile.
private def compile_association_source(body : String) : Tuple(Bool, String)
  repo_root = File.expand_path("../../..", __DIR__)
  source = <<-CR
    require "sqlite3"
    require "../../../src/grant"
    require "../../../src/adapter/sqlite"

    class OvThing < Grant::Base
      connection sqlite
      table ov_things
      column id : Int64, primary: true
      column ov_owner_id : Int64?
    end

    class OvOwner < Grant::Base
      connection sqlite
      table ov_owners
      column id : Int64, primary: true
    #{body}
    end
    CR
  file = File.new(File.join(__DIR__, "ov_compile_check_#{Process.pid}.cr"), "w")
  file.print(source)
  file.close
  begin
    error = IO::Memory.new
    status = Process.run("crystal-alpha", ["build", "--no-codegen", "--no-color", file.path], error: error, output: Process::Redirect::Close, chdir: repo_root)
    {status.success?, error.to_s}
  ensure
    file.delete
  end
end

describe "association option validation" do
  it "accepts every documented option" do
    ok, output = compile_association_source(<<-CR)
      belongs_to :ov_parent, class_name: OvOwner, foreign_key: ov_parent_id : Int64?, primary_key: id, optional: true, touch: true, inverse_of: false, strict_loading: true, autosave: true, validate: true, index_errors: true
      has_one :ov_single, class_name: OvThing, foreign_key: :ov_owner_id, primary_key: :id, dependent: :destroy, autosave: true, validate: true, strict_loading: true, inverse_of: false
      has_many :ov_things, class_name: OvThing, foreign_key: :ov_owner_id, primary_key: :id, singular: :ov_thing, dependent: :delete_all, autosave: true, validate: true, index_errors: true, strict_loading: true, inverse_of: false, before_add: :noop, after_add: :noop, before_remove: :noop, after_remove: :noop, counter_cache: true
      has_many :ov_relayed, through: :ov_things, source: :ov_thing, class_name: OvThing
      def noop(record : OvThing); end
    CR
    ok.should be_true, output
  end

  it "rejects an unknown belongs_to option and lists the valid ones" do
    ok, output = compile_association_source(%(belongs_to :ov_parent, class_name: OvOwner, foriegn_key: :x, optional: true))
    ok.should be_false
    output.should contain("Unknown option `foriegn_key:` for `belongs_to :ov_parent`")
    output.should contain("Valid options:")
    output.should contain("foreign_key:")
  end

  it "rejects an unknown has_one option" do
    ok, output = compile_association_source(%(has_one :ov_single, class_name: OvThing, dependant: :destroy))
    ok.should be_false
    output.should contain("Unknown option `dependant:` for `has_one :ov_single`")
  end

  it "rejects an unknown has_many option" do
    ok, output = compile_association_source(%(has_many :ov_things, class_name: OvThing, order: :name))
    ok.should be_false
    output.should contain("Unknown option `order:` for `has_many :ov_things`")
  end

  it "rejects an unknown option on a polymorphic has_many and has_one" do
    ok, output = compile_association_source(%(has_many :ov_things, class_name: OvThing, as: :ov_subject, bogus: 1))
    ok.should be_false
    output.should contain("Unknown option `bogus:` for `has_many :ov_things`")
    ok, output = compile_association_source(%(has_one :ov_single, class_name: OvThing, as: :ov_subject, bogus: 1))
    ok.should be_false
    output.should contain("Unknown option `bogus:` for `has_one :ov_single`")
  end

  it "rejects an unknown option on a typed declaration" do
    ok, output = compile_association_source(%(has_many ov_things : OvThing, foreign_key: :ov_owner_id, nope: true))
    ok.should be_false
    output.should contain("Unknown option `nope:` for `has_many :ov_things`")
  end

  it "rejects source_type without through" do
    ok, output = compile_association_source(%(has_many :ov_things, class_name: OvThing, source_type: OvThing))
    ok.should be_false
    output.should contain("`source_type:` on `has_many :ov_things`")
    output.should contain("needs `through:`")
  end

  it "rejects dependent values the association type does not support" do
    {
      %(has_many :ov_things, class_name: OvThing, dependent: :delete)                => "has_many",
      %(has_many :ov_things, class_name: OvThing, dependent: :bogus)                 => "has_many",
      %(has_one :ov_single, class_name: OvThing, dependent: :delete_all)             => "has_one",
      %(belongs_to :ov_parent, class_name: OvOwner, dependent: :nullify)             => "belongs_to",
      %(belongs_to :ov_parent, class_name: OvOwner, dependent: :restrict_with_error) => "belongs_to",
    }.each do |declaration, kind|
      ok, output = compile_association_source(declaration)
      ok.should be_false, "expected #{declaration} to fail"
      output.should contain("Unknown `dependent: ")
      output.should contain("(#{kind})")
      output.should contain("Supported values:")
    end
  end

  it "accepts the dependent values each association type supports" do
    ok, output = compile_association_source(<<-CR)
      has_many :ov_a, class_name: OvThing, foreign_key: :ov_owner_id, dependent: :restrict_with_error
      has_many :ov_b, class_name: OvThing, foreign_key: :ov_owner_id, dependent: :restrict_with_exception
      has_many :ov_c, class_name: OvThing, foreign_key: :ov_owner_id, dependent: :nullify
      has_one :ov_d, class_name: OvThing, foreign_key: :ov_owner_id, dependent: :delete
      belongs_to :ov_e, class_name: OvOwner, foreign_key: ov_e_id : Int64?, dependent: :destroy, optional: true
    CR
    ok.should be_true, output
  end
end
