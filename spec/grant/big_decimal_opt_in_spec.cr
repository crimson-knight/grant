require "../spec_helper"
require "../support/crystal_compiler"

# BigDecimal support is opt-in: `require "grant/big_decimal"` before
# `require "grant"` turns on BigDecimal columns, BigDecimal query values and
# exact decimal sums. The suite opts in (spec_helper), so the first half of
# this file shows each one working on the current adapter; the "without the
# opt-in" specs build separate programs on Grant's default path, run them on
# the same database and check that their binaries link no GMP.
{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class BigDecimalOptInAmount < Grant::Base
    connection {{ adapter_literal }}
    table big_decimal_opt_in_amounts

    column id : Int64, primary: true
    column amount : BigDecimal, precision: 30, scale: 6
    column whole_units : BigDecimal?, precision: 10, scale: 0
    column rate : BigDecimal?
  end
{% end %}

# The adapter file and class a default-path program uses for the current adapter.
private DEFAULT_PATH_ADAPTERS = {
  "sqlite" => {"sqlite", "Sqlite"},
  "pg"     => {"pg", "Pg"},
  "mysql"  => {"mysql", "Mysql"},
}

private record DefaultPathBuild, built : Bool, compiler_output : String, binary_path : String

# Builds *body* as a program that requires Grant without `grant/big_decimal`.
# *before_grant* is placed ahead of `require "grant"`.
private def build_on_default_path(body : String, before_grant : String = "", check_only : Bool = false) : DefaultPathBuild
  repo_root = File.expand_path("../..", __DIR__)
  adapter_file, adapter_class = DEFAULT_PATH_ADAPTERS[CURRENT_ADAPTER]
  # The suite run on Grant's SQLite engine runs these programs on it too, so
  # C SQLite never turns the shared database file to WAL. The engine is
  # compiled in only when the program requires it.
  on_grant_engine = CURRENT_ADAPTER == "sqlite" && GRANT_SQLITE_ENGINE == :grant
  engine_setup = on_grant_engine ? %(require "../../src/adapter/sqlite/grant_engine"\nGrant.settings.sqlite_engine = :grant) : ""
  source = <<-CR
    #{before_grant}
    require "../../src/grant"
    require "../../src/adapter/#{adapter_file}"
    #{engine_setup}
    Grant::Connections << Grant::Adapter::#{adapter_class}.new(name: "primary", url: ENV["GRANT_DEFAULT_PATH_URL"])

    #{body}
    CR
  # Written next to the spec so the relative requires above resolve.
  source_path = File.join(__DIR__, "big_decimal_opt_in_check_#{Process.pid}.cr")
  binary_path = File.tempname("grant_default_path")
  File.write(source_path, source)
  begin
    output = IO::Memory.new
    arguments = check_only ? ["build", "--no-codegen", "--no-color", source_path] : ["build", "--no-color", "-o", binary_path, source_path]
    status = Process.run(spec_crystal_compiler, arguments, error: output, output: output, chdir: repo_root)
    DefaultPathBuild.new(status.success?, output.to_s, binary_path)
  ensure
    File.delete(source_path)
  end
end

private def output_of(command : String, arguments : Array(String), env : Process::Env = nil) : {Bool, String}
  output = IO::Memory.new
  status = Process.run(command, arguments, env: env, error: output, output: output)
  {status.success?, output.to_s}
end

describe "BigDecimal support behind require \"grant/big_decimal\"" do
  before_each { BigDecimalOptInAmount.migrator.drop_and_create }
  after_all { BigDecimalOptInAmount.migrator.drop }

  it "is compiled in when grant/big_decimal comes before grant" do
    Grant::BIG_DECIMAL_SUPPORT.should be_true
    BigDecimal.new("1.5").is_a?(Grant::Columns::Type).should be_true
    BigDecimal.new("1.5").is_a?(Grant::Query::Builder::SumValue).should be_true
    BigDecimal.new("1.5").is_a?(Grant::Schema::DefaultLiteral).should be_true
  end

  it "round trips positive, negative, zero and small values" do
    ["0", "0.000001", "-0.000001", "123456789.123456", "-987654321.654321"].each do |text|
      row = BigDecimalOptInAmount.create!(amount: BigDecimal.new(text))
      found = BigDecimalOptInAmount.find!(row.id)
      found.amount.should be_a(BigDecimal)
      found.amount.should eq(BigDecimal.new(text))
    end
  end

  # SQLite keeps a NUMERIC column as a 64-bit float past about 15 significant
  # digits, which is the documented limit of a BigDecimal column there.
  {% if (env("CURRENT_ADAPTER") || "sqlite") == "sqlite" %}
    it "keeps 15 significant digits on SQLite" do
      row = BigDecimalOptInAmount.create!(amount: BigDecimal.new("999999999.999999"))
      BigDecimalOptInAmount.find!(row.id).amount.should eq(BigDecimal.new("999999999.999999"))
    end
  {% else %}
    it "keeps every digit of a 30 digit value" do
      exact = BigDecimal.new("123456789012345678901234.123456")
      row = BigDecimalOptInAmount.create!(amount: exact)
      BigDecimalOptInAmount.find!(row.id).amount.should eq(exact)
      BigDecimalOptInAmount.where(amount: exact).count.should eq(1)
      BigDecimalOptInAmount.sum(:amount).should eq(exact)
    end
  {% end %}

  it "rounds half away from zero to the declared scale" do
    {
      "1.0000005"  => "1.000001",
      "-1.0000005" => "-1.000001",
      "1.0000004"  => "1",
      "-1.0000004" => "-1",
    }.each do |assigned, rounded|
      row = BigDecimalOptInAmount.new(amount: BigDecimal.new(assigned))
      row.amount.should eq(BigDecimal.new(rounded))
      row.save!
      BigDecimalOptInAmount.find!(row.id).amount.should eq(BigDecimal.new(rounded))
    end

    {"2.5" => "3", "-2.5" => "-3", "2.4" => "2"}.each do |assigned, rounded|
      row = BigDecimalOptInAmount.create!(amount: BigDecimal.new(1), whole_units: BigDecimal.new(assigned))
      BigDecimalOptInAmount.find!(row.id).whole_units.should eq(BigDecimal.new(rounded))
    end
  end

  it "stores and finds NULL in a nilable column" do
    row = BigDecimalOptInAmount.create!(amount: BigDecimal.new("1"))
    found = BigDecimalOptInAmount.find!(row.id)
    found.rate.should be_nil
    found.whole_units.should be_nil
    BigDecimalOptInAmount.where(rate: nil).count.should eq(1)

    found.update!(rate: BigDecimal.new(42))
    BigDecimalOptInAmount.find!(row.id).rate.should eq(BigDecimal.new(42))
    BigDecimalOptInAmount.where(rate: nil).count.should eq(0)

    found.update!(rate: nil)
    BigDecimalOptInAmount.find!(row.id).rate.should be_nil
  end

  it "sums a decimal column exactly" do
    BigDecimalOptInAmount.create!(amount: BigDecimal.new("0.1"))
    BigDecimalOptInAmount.create!(amount: BigDecimal.new("0.2"))
    BigDecimalOptInAmount.create!(amount: BigDecimal.new("-1000000.300001"))

    BigDecimalOptInAmount.sum(:amount).should eq(BigDecimal.new("-1000000.000001"))
    typed = BigDecimalOptInAmount.all.sum(:amount, as: BigDecimal)
    typed.should be_a(BigDecimal)
    typed.should eq(BigDecimal.new("-1000000.000001"))
    BigDecimalOptInAmount.where(rate: nil).sum(:rate).should eq(0)
  end

  describe "without the opt-in" do
    it "stores numbers, sums them and links no GMP" do
      build = build_on_default_path(<<-'CR')
        class DecimalFreeLedger < Grant::Base
          connection primary
          table big_decimal_opt_in_default_ledgers

          column id : Int64, primary: true
          column cents : Int64
          column ratio : Float64
          column rebate : Float64?
          column units : Int32?
        end

        DecimalFreeLedger.migrator.drop_and_create
        first = DecimalFreeLedger.create!(cents: 9_007_199_254_740_993_i64, ratio: 0.5, rebate: 1.25, units: 3)
        second = DecimalFreeLedger.create!(cents: 10_i64, ratio: 1.25)
        found = DecimalFreeLedger.find!(first.id)
        without_values = DecimalFreeLedger.find!(second.id)
        ids = DecimalFreeLedger.order(:id).ids.map(&.as(Int64))

        puts "support: #{Grant::BIG_DECIMAL_SUPPORT}"
        puts "column values: #{Grant::Columns::Type}"
        puts "round trip: #{found.cents} #{found.ratio} #{found.rebate} #{found.units}"
        puts "null: #{without_values.rebate.inspect} #{without_values.units.inspect} #{DecimalFreeLedger.where(rebate: nil).count}"
        puts "integer sum: #{DecimalFreeLedger.sum(:cents)} #{DecimalFreeLedger.sum(:cents).class}"
        puts "float sum: #{DecimalFreeLedger.sum(:ratio)} #{DecimalFreeLedger.sum(:ratio).class}"
        puts "integer expression sum: #{DecimalFreeLedger.all.sum("cents * 2")} #{DecimalFreeLedger.all.sum("cents * 2").class}"
        puts "fractional expression sum: #{DecimalFreeLedger.all.sum("ratio * 3")} #{DecimalFreeLedger.all.sum("ratio * 3").class}"
        puts "as Int64: #{DecimalFreeLedger.all.sum("ratio * 4", as: Int64)} #{DecimalFreeLedger.all.sum(:cents, as: Int64)}"
        puts "as Float64: #{DecimalFreeLedger.all.sum(:ratio, as: Float64)}"
        begin
          DecimalFreeLedger.all.sum(:ratio, as: Int64)
        rescue error : ArgumentError
          puts "fractional as Int64: #{error.message}"
        end
        puts "chunked: #{DecimalFreeLedger.where(id: ids).in_chunks(of: 1).sum(:cents)} #{DecimalFreeLedger.where(id: ids).in_chunks(of: 1).sum(:ratio)}"
        puts "average: #{DecimalFreeLedger.avg(:ratio)}"
        DecimalFreeLedger.migrator.drop
        CR
      build.built.should be_true, build.compiler_output

      begin
        ran, output = output_of(build.binary_path, [] of String, {"GRANT_DEFAULT_PATH_URL" => ADAPTER_URL})
        ran.should be_true, output
        output.should contain("support: false")
        output.lines.find!(&.starts_with?("column values: ")).should_not contain("BigDecimal")
        output.should contain("round trip: 9007199254740993 0.5 1.25 3")
        output.should contain("null: nil nil 1")
        output.should contain("integer sum: 9007199254741003 Int64")
        output.should contain("float sum: 1.75 Float64")
        output.should contain("integer expression sum: 18014398509482006 Int64")
        output.should contain("fractional expression sum: 5.25 Float64")
        output.should contain("as Int64: 7 9007199254741003")
        output.should contain("as Float64: 1.75")
        output.should contain("fractional as Int64: 1.75 does not fit Int64 exactly")
        output.should contain("chunked: 9007199254741003 1.75")
        output.should contain("average: 0.875")

        library_lister = {% if flag?(:darwin) %} {"otool", ["-L"]} {% else %} {"ldd", [] of String} {% end %}
        listed, libraries = output_of(library_lister[0], library_lister[1] + [build.binary_path])
        listed.should be_true, libraries
        libraries.should_not contain("libgmp")
        _, symbols = output_of("nm", [build.binary_path])
        symbols.should_not contain("__gmp")
      ensure
        File.delete?(build.binary_path)
      end
    end

    it "explains that a BigDecimal column needs grant/big_decimal" do
      build = build_on_default_path(<<-CR, check_only: true)
        class BigDecimalOptInCheck < Grant::Base
          connection primary
          table big_decimal_opt_in_checks
          column id : Int64, primary: true
          column price : BigDecimal?, precision: 12, scale: 2
        end
        CR
      build.built.should be_false
      build.compiler_output.should contain("BigDecimalOptInCheck#price is a BigDecimal")
      build.compiler_output.should contain(%(require "grant/big_decimal"))
    end

    it "explains it when big is required after grant" do
      build = build_on_default_path(<<-CR, check_only: true)
        require "big"

        class BigDecimalOptInCheck < Grant::Base
          connection primary
          table big_decimal_opt_in_checks
          column id : Int64, primary: true
          column price : BigDecimal
        end
        CR
      build.built.should be_false
      build.compiler_output.should contain(%(require "grant/big_decimal"))
    end

    it "explains that sum(as: BigDecimal) needs grant/big_decimal" do
      build = build_on_default_path(<<-CR, check_only: true)
        require "big"

        class BigDecimalOptInCheck < Grant::Base
          connection primary
          table big_decimal_opt_in_checks
          column id : Int64, primary: true
          column cents : Int64
        end
        BigDecimalOptInCheck.all.sum(:cents, as: BigDecimal)
        CR
      build.built.should be_false
      build.compiler_output.should contain("sum(as: BigDecimal)")
      build.compiler_output.should contain(%(require "grant/big_decimal"))
    end

    it "explains that grant/big_decimal comes before grant" do
      build = build_on_default_path(%(require "../../src/grant/big_decimal"), check_only: true)
      build.built.should be_false
      build.compiler_output.should contain(%(move `require "grant/big_decimal"` before `require "grant"`))
    end

    it "enables the support for an app that requires big before grant" do
      build = build_on_default_path(<<-CR, before_grant: %(require "big"), check_only: true)
        class BigDecimalOptInCheck < Grant::Base
          connection primary
          table big_decimal_opt_in_checks
          column id : Int64, primary: true
          column price : BigDecimal, precision: 12, scale: 2
        end
        BigDecimalOptInCheck.new(price: BigDecimal.new("1.005")).price
        BigDecimalOptInCheck.all.sum(:price, as: BigDecimal)
        CR
      build.built.should be_true, build.compiler_output
    end
  end
end
