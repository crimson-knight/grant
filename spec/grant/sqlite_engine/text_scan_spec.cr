require "spec"
require "../../../src/grant/sqlite_engine"

private alias TextScan = Grant::SQLiteEngine::TextScan
private alias Query = Grant::SQLiteEngine::Query

private def function_names(text : String) : Array(String)
  list_of_names = [] of String
  TextScan.each_function_name(text) { |name| list_of_names << name }
  list_of_names
end

describe Grant::SQLiteEngine::TextScan do
  describe ".contains_word?" do
    it "finds a keyword at the start, the end and alone" do
      TextScan.contains_word?("SELECT 1", "SELECT").should be_true
      TextScan.contains_word?("x IN (select 1)", "SELECT").should be_true
      TextScan.contains_word?("1 + Select", "SELECT").should be_true
      TextScan.contains_word?("select", "SELECT").should be_true
    end

    it "skips a keyword inside a longer word" do
      TextScan.contains_word?("selected", "SELECT").should be_false
      TextScan.contains_word?("preselect", "SELECT").should be_false
      TextScan.contains_word?("_select", "SELECT").should be_false
      TextScan.contains_word?("select1", "SELECT").should be_false
      TextScan.contains_word?("", "SELECT").should be_false
    end

    it "treats $ and punctuation as word ends, and a non-ASCII letter as part of the word" do
      TextScan.contains_word?("$select$", "SELECT").should be_true
      TextScan.contains_word?("\"select\"", "SELECT").should be_true
      TextScan.contains_word?("éselect", "SELECT").should be_false
      TextScan.contains_word?("selecté", "SELECT").should be_false
    end

    it "matches case exactly when asked" do
      TextScan.contains_word?("a = col", "col", case_insensitive: false).should be_true
      TextScan.contains_word?("a = Col", "col", case_insensitive: false).should be_false
    end

    it "takes a name that starts or ends with a non-word byte" do
      TextScan.contains_word?("f($x)", "$x", case_insensitive: false).should be_true
      TextScan.contains_word?("a$x", "$x", case_insensitive: false).should be_false
    end

    context "with WordBytes::AsciiIdentifier" do
      it "lets $ continue the name and a non-ASCII byte end it" do
        ascii = TextScan::WordBytes::AsciiIdentifier
        TextScan.contains_word?("a$b + 1", "a", word_bytes: ascii).should be_false
        TextScan.contains_word?("$a", "a", word_bytes: ascii).should be_false
        TextScan.contains_word?("éa", "a", word_bytes: ascii).should be_true
        TextScan.contains_word?("[Name] = 1", "name", word_bytes: ascii).should be_true
        TextScan.contains_word?("`name`", "NAME", word_bytes: ascii).should be_true
        TextScan.contains_word?("x\n", "x", word_bytes: ascii).should be_true
      end
    end
  end

  describe ".contains_any_word?" do
    it "finds any of the words, ignoring case" do
      operators = Query::StatementJournal::PATTERN_OPERATORS
      TextScan.contains_any_word?("a like 'x%'", operators).should be_true
      TextScan.contains_any_word?("a REGEXP b", operators).should be_true
      TextScan.contains_any_word?("likely = 1", operators).should be_false
    end
  end

  describe ".contains_ignoring_case?" do
    it "finds the fragment anywhere" do
      TextScan.contains_ignoring_case?("FOREIGN KEY (a) REFERENCES p(b)", "references").should be_true
      TextScan.contains_ignoring_case?("no_refs_here", "references").should be_false
      TextScan.contains_ignoring_case?("ref", "references").should be_false
    end
  end

  describe ".blank_quoted_strings" do
    it "blanks each string, doubled quotes included" do
      TextScan.blank_quoted_strings("a = 'x' AND b = 'it''s'").should eq("a = '' AND b = ''")
      TextScan.blank_quoted_strings("'f(x)' || g('like')").should eq("'' || g('')")
      TextScan.blank_quoted_strings("''").should eq("''")
      TextScan.blank_quoted_strings("no strings").should eq("no strings")
    end

    it "ends a string left open at its last doubled quote, as the regex's backtracking does" do
      TextScan.blank_quoted_strings("'a''b''c").should eq("'''c")
      TextScan.blank_quoted_strings("x 'open").should eq("x 'open")
      TextScan.blank_quoted_strings("'''").should eq("'''")
      TextScan.blank_quoted_strings("'").should eq("'")
    end
  end

  describe ".each_function_name" do
    it "yields each name before a parenthesis" do
      function_names("abs(x) + count (*) + t.f(y)").should eq(%w[abs count f])
      function_names("a$b(1)").should eq(["a$b"])
    end

    it "starts a name at the first letter or underscore" do
      function_names("9e(x)").should eq(["e"])
      function_names("$x(1)").should eq(["x"])
      function_names("éf(1)").should eq(["f"])
    end

    it "skips names with no parenthesis after them" do
      function_names("a b (c)").should eq(["b"])
      function_names("x IN (1)").should eq(["IN"])
      function_names("plain").should be_empty
    end
  end

  describe ".decimal_number?" do
    it "reads integers, fractions and exponents with a sign" do
      %w[0 -1 +2 1. .5 1.5 1e5 1E-5 -.5e+10 007].each { |text| TextScan.decimal_number?(text).should be_true }
    end

    it "refuses anything else" do
      ["", "+", ".", "1e", "e5", "1.2.3", "0x10", " 1", "1 ", "1e+", "--1", "١"].each do |text|
        TextScan.decimal_number?(text).should be_false
      end
    end
  end

  describe ".mantissa_end and .exponent_end" do
    it "return the index after each part, or nil" do
      bytes = "12.5e-3x".to_slice
      TextScan.mantissa_end(bytes, 0).should eq(4)
      TextScan.exponent_end(bytes, 4).should eq(7)
      TextScan.mantissa_end(".x".to_slice, 0).should be_nil
      TextScan.exponent_end("e+".to_slice, 0).should be_nil
    end
  end

  describe ".first_digits" do
    it "returns the first run of digits" do
      TextScan.first_digits("(10, 2)").should eq("10")
      TextScan.first_digits("VARCHAR(255)").should eq("255")
      TextScan.first_digits("(n)").should be_nil
      TextScan.first_digits("").should be_nil
    end
  end

  describe ".partial_index_condition" do
    it "returns the text after the first WHERE, stripped" do
      TextScan.partial_index_condition("CREATE INDEX i ON t(a) WHERE a > 0").should eq("a > 0")
      TextScan.partial_index_condition("CREATE INDEX i ON t(a)\nwhere\n  a IS NOT NULL\n").should eq("a IS NOT NULL")
      TextScan.partial_index_condition("CREATE INDEX i ON t(a) WHERE ").should eq("")
    end

    it "returns nil without a whitespace-delimited WHERE" do
      TextScan.partial_index_condition("CREATE INDEX i ON t(somewhere)").should be_nil
      TextScan.partial_index_condition("CREATE INDEX i ON t(a) WHERE").should be_nil
      TextScan.partial_index_condition("").should be_nil
    end
  end
end

describe Grant::SQLiteEngine::Affinity do
  describe ".parse_real_literal" do
    it "gives infinity or zero for an exponent out of range" do
      Grant::SQLiteEngine::Affinity.parse_real_literal("1e999").should eq(Float64::INFINITY)
      Grant::SQLiteEngine::Affinity.parse_real_literal("-1e999").should eq(-Float64::INFINITY)
      Grant::SQLiteEngine::Affinity.parse_real_literal("1e-999").should eq(0.0)
      Grant::SQLiteEngine::Affinity.parse_real_literal("1.5").should eq(1.5)
      Grant::SQLiteEngine::Affinity.parse_real_literal("1e").should be_nil
    end
  end
end

describe Grant::SQLiteEngine::Query::PragmaOptimize do
  describe ".integer_prefix" do
    it "reads a leading decimal or hexadecimal integer, else 0" do
      Query::PragmaOptimize.integer_prefix("0x10").should eq(16)
      Query::PragmaOptimize.integer_prefix(" 42abc").should eq(42)
      Query::PragmaOptimize.integer_prefix("-7").should eq(-7)
      Query::PragmaOptimize.integer_prefix("0xg").should eq(0)
      Query::PragmaOptimize.integer_prefix("abc").should eq(0)
      Query::PragmaOptimize.integer_prefix("99999999999").should eq(Int32::MAX)
    end
  end
end

describe Grant::SQLiteEngine::Query::ExpressionCompiler do
  describe ".json_function_name?" do
    it "accepts json.c-shaped names only" do
      %w[json jsonb json_extract jsonb_group_array json__x].each do |name|
        Query::ExpressionCompiler.json_function_name?(name).should be_true
      end
      %w[jsonx json_ json_A xjson JSON jsonbb].each do |name|
        Query::ExpressionCompiler.json_function_name?(name).should be_false
      end
    end
  end

  describe ".continuing_error? and .lookup_error?" do
    it "match on the start of the message" do
      Query::ExpressionCompiler.continuing_error?(Exception.new("no such function: f")).should be_true
      Query::ExpressionCompiler.continuing_error?(Exception.new("x: no such function")).should be_false
      Query::ExpressionCompiler.lookup_error?(Exception.new("ambiguous column name: a")).should be_true
      Query::ExpressionCompiler.lookup_error?(Exception.new(nil)).should be_false
    end
  end
end

describe Grant::SQLiteEngine::Query::Compiler do
  describe ".expand_error?" do
    it "matches the expand-phase messages" do
      ["no such table: t", "multiple recursive references: c", "multiple references to x", "too many columns",
       "'f' is not a function", "'a' b' is not a function"].each do |message|
        Query::Compiler.expand_error?(Exception.new(message)).should be_true
      end
    end

    it "refuses a quoted name across lines and other messages" do
      ["'a\nb' is not a function", "' is not a function", "x' is not a function", "no such column: c"].each do |message|
        Query::Compiler.expand_error?(Exception.new(message)).should be_false
      end
    end
  end
end
