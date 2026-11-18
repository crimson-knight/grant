require "../spec_helper"
require "../../src/grant/regex"
require "../support/crystal_compiler"

# Regex support is opt-in: `require "grant/regex"` turns on `validates_format_of`,
# Regex `filter_attributes`, the SQLite `REGEXP` operator and the
# `EMAIL_REGEX`/`URL_REGEX` constants. This file opts in and shows each one
# working; the "without the opt-in" specs compile separate programs that do not.
{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class RegexOptInAccount < Grant::Base
    connection {{ adapter_literal }}
    table regex_opt_in_accounts

    column id : Int64, primary: true
    column handle : String?
    column recovery_phrase : String?

    validates_format_of :handle, with: /\A[a-z]+\z/, without: /\Aadmin\z/
    filter_attributes /phrase\z/
  end
{% end %}

private def compile_without_opt_in(body : String, run : Bool = false) : {Bool, String}
  repo_root = File.expand_path("../..", __DIR__)
  source = <<-CR
    require "../../src/grant/drivers/sqlite3/sqlite3"
    require "../../src/grant"
    require "../../src/adapter/sqlite"

    #{body}
    CR
  # Written next to the spec so the relative requires above resolve.
  file = File.new(File.join(__DIR__, "regex_opt_in_check_#{Process.pid}.cr"), "w")
  file.print(source)
  file.close
  begin
    output = IO::Memory.new
    arguments = run ? ["run", "--no-color", file.path] : ["build", "--no-codegen", "--no-color", file.path]
    status = Process.run(spec_crystal_compiler, arguments, error: output, output: output, chdir: repo_root)
    {status.success?, output.to_s}
  ensure
    file.delete
  end
end

describe "Regex support behind require \"grant/regex\"" do
  before_all { RegexOptInAccount.migrator.drop_and_create }

  it "runs validates_format_of with: and without:" do
    RegexOptInAccount.new(handle: "ada").valid?.should be_true
    RegexOptInAccount.new(handle: "Ada1").valid?.should be_false
    RegexOptInAccount.new(handle: "admin").valid?.should be_false
  end

  it "filters attributes a model names with a Regex" do
    account = RegexOptInAccount.new(handle: "ada", recovery_phrase: "correct horse")
    account.inspect.should contain("recovery_phrase: [FILTERED]")
    account.inspect.should contain(%(handle: "ada"))
  end

  it "accepts Regex entries in Grant.settings.filter_attributes" do
    Grant.settings.filter_attributes = [/\Ahandle\z/] of String | Regex
    begin
      RegexOptInAccount.new(handle: "ada").inspect.should contain("handle: [FILTERED]")
    ensure
      Grant.settings.filter_attributes = [] of Grant::AttributeFilter
    end
  end

  it "keeps EMAIL_REGEX and URL_REGEX in step with the hand-written checks" do
    formats = Grant::Validators::BuiltIn::CommonFormats
    ["user@example.com", "user@example", "a+b@x.co", "not-an-email"].each do |value|
      formats.email?(value).should eq(value.matches?(Grant::Validators::BuiltIn::CommonFormats::EMAIL_REGEX))
    end
    ["https://example.com/a?b=c", "ftp://example.com", "http://www.example.org"].each do |value|
      formats.url?(value).should eq(value.matches?(Grant::Validators::BuiltIn::CommonFormats::URL_REGEX))
    end
  end

  {% if (env("CURRENT_ADAPTER") || "sqlite") == "sqlite" %}
    it "registers the SQLite REGEXP operator" do
      RegexOptInAccount.create!(handle: "grace")
      RegexOptInAccount.where("handle REGEXP ?", "^gr").count.should eq 1
    end
  {% end %}

  describe "without the opt-in" do
    it "explains that validates_format_of needs grant/regex" do
      ok, message = compile_without_opt_in(<<-CR)
        class RegexOptInCheck < Grant::Base
          connection sqlite
          table regex_opt_in_checks
          column id : Int64, primary: true
          column handle : String?
          validates_format_of :handle, with: /a/
        end
        CR
      ok.should be_false
      message.should contain(%(require "grant/regex"))
    end

    it "explains that a Regex filter_attributes needs grant/regex" do
      ok, message = compile_without_opt_in(<<-CR)
        class RegexOptInCheck < Grant::Base
          connection sqlite
          table regex_opt_in_checks
          column id : Int64, primary: true
          filter_attributes /secret/
        end
        RegexOptInCheck.filter_attributes
        CR
      ok.should be_false
      message.should contain(%(require "grant/regex"))
    end

    it "leaves REGEXP unregistered on SQLite connections" do
      ok, message = compile_without_opt_in(<<-'CR', run: true)
        adapter = Grant::Adapter::Sqlite.new(name: "probe", url: "sqlite3::memory:")
        begin
          adapter.open(&.scalar("SELECT 'abc' REGEXP 'b'"))
          puts "REGEXP available"
        rescue ex
          puts "REGEXP missing: #{ex.message}"
        end
        CR
      ok.should be_true, message
      message.should contain("REGEXP missing")
      message.should contain("no such function")
    end
  end
end
