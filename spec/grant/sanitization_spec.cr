require "../spec_helper"

describe Grant::Sanitization do
  # Live adapter for the database under test (SQLite locally), used to verify
  # adapter-aware quoting (booleans, identifier quote char).
  adapter = Chat.adapter

  describe ".quote" do
    it "quotes nil as NULL" do
      Grant::Sanitization.quote(nil).should eq "NULL"
    end

    it "quotes integers without quoting" do
      Grant::Sanitization.quote(42).should eq "42"
      Grant::Sanitization.quote(-7_i64).should eq "-7"
    end

    it "quotes floats without quoting" do
      Grant::Sanitization.quote(3.5).should eq "3.5"
    end

    it "quotes strings with surrounding single quotes" do
      Grant::Sanitization.quote("hello").should eq "'hello'"
    end

    it "escapes embedded single quotes by doubling them" do
      Grant::Sanitization.quote("O'Brien").should eq "'O''Brien'"
    end

    it "strips embedded NUL bytes from strings" do
      Grant::Sanitization.quote("a\0b").should eq "'ab'"
    end

    it "quotes booleans portably without an adapter (1/0)" do
      Grant::Sanitization.quote(true).should eq "1"
      Grant::Sanitization.quote(false).should eq "0"
    end

    it "quotes booleans per the adapter when one is given" do
      # SQLite (local) and PG => TRUE/FALSE
      expected_true = adapter.quote_boolean(true)
      expected_false = adapter.quote_boolean(false)
      Grant::Sanitization.quote(true, adapter).should eq expected_true
      Grant::Sanitization.quote(false, adapter).should eq expected_false
    end

    it "quotes Time as a single-quoted UTC timestamp" do
      t = Time.utc(2024, 1, 2, 3, 4, 5)
      Grant::Sanitization.quote(t).should eq "'2024-01-02 03:04:05'"
    end

    it "quotes bytes as a hex blob literal" do
      Grant::Sanitization.quote(Bytes[0xDE, 0xAD]).should eq "x'dead'"
    end

    it "raises for an unquotable type" do
      expect_raises(ArgumentError, /cannot quote/) do
        Grant::Sanitization.quote([1, 2, 3])
      end
    end
  end

  describe ".quote_identifier" do
    it "double-quotes identifiers without an adapter" do
      Grant::Sanitization.quote_identifier("users").should eq %("users")
    end

    it "escapes embedded double quotes without an adapter" do
      Grant::Sanitization.quote_identifier(%(we"ird)).should eq %("we""ird")
    end

    it "delegates to the adapter when one is given" do
      Grant::Sanitization.quote_identifier("users", adapter).should eq adapter.quote("users")
    end

    it "neutralizes an identifier-based injection attempt" do
      # An attacker-controlled column name must not be able to break out of the
      # quoted identifier and inject a subquery.
      malicious = %(id"; DROP TABLE users; --)
      quoted = Grant::Sanitization.quote_identifier(malicious, adapter)
      # The injected quote char is doubled, so the whole thing stays one identifier.
      quoted.should eq adapter.quote(malicious)
      quoted.should contain "\"\""
    end
  end

  describe ".sanitize_sql_array" do
    it "substitutes a single placeholder" do
      Grant::Sanitization.sanitize_sql_array(["age > ?", 18]).should eq "age > 18"
    end

    it "substitutes multiple placeholders in order" do
      result = Grant::Sanitization.sanitize_sql_array(["name = ? AND age > ?", "Alice", 30])
      result.should eq "name = 'Alice' AND age > 30"
    end

    it "quotes string values, escaping embedded quotes" do
      result = Grant::Sanitization.sanitize_sql_array(["name = ?", "O'Brien"])
      result.should eq "name = 'O''Brien'"
    end

    it "accepts a splat form" do
      Grant::Sanitization.sanitize_sql_array("id = ?", 5).should eq "id = 5"
    end

    it "returns the SQL unchanged when there are no placeholders" do
      Grant::Sanitization.sanitize_sql_array(["1 = 1"]).should eq "1 = 1"
    end

    it "does not treat a ? inside a single-quoted literal as a placeholder" do
      # The ? inside 'is it? maybe' is literal text, only the trailing ? binds.
      result = Grant::Sanitization.sanitize_sql_array(["note = 'is it? maybe' AND id = ?", 7])
      result.should eq "note = 'is it? maybe' AND id = 7"
    end

    it "raises when there are more placeholders than values" do
      expect_raises(Grant::Sanitization::WrongNumberOfArguments, /wrong number of bind variables/) do
        Grant::Sanitization.sanitize_sql_array(["a = ? AND b = ?", 1])
      end
    end

    it "raises when there are more values than placeholders" do
      expect_raises(Grant::Sanitization::WrongNumberOfArguments) do
        Grant::Sanitization.sanitize_sql_array(["a = ?", 1, 2])
      end
    end

    it "raises on an empty array" do
      expect_raises(ArgumentError) do
        Grant::Sanitization.sanitize_sql_array([] of String)
      end
    end
  end

  describe "SQL injection neutralization" do
    it "neutralizes a classic DROP TABLE injection in a string value" do
      payload = "'; DROP TABLE users; --"
      result = Grant::Sanitization.sanitize_sql_array(["name = ?", payload])
      # The entire payload is contained within a single quoted literal: the
      # leading quote is doubled, so it cannot terminate the string and the
      # DROP TABLE is inert data, not executable SQL.
      result.should eq "name = '''; DROP TABLE users; --'"
      result.should_not eq "name = ''; DROP TABLE users; --"
    end

    it "neutralizes injection and is safe to execute against a real database" do
      # Prove the neutralized fragment is genuinely inert SQL: it parses, runs as
      # a harmless string comparison, drops NOTHING, and returns normally.
      #
      # Uses a throwaway in-memory SQLite database created and owned by this
      # test, so it is independent of the shared connection pool (which other
      # pre-existing failing specs may have left in a refused state).
      DB.open("sqlite3:%3Amemory%3A") do |db|
        db.exec "CREATE TABLE victims (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "INSERT INTO victims (name) VALUES ('safe-row')"

        payload = "'; DROP TABLE victims; --"
        fragment = Grant::Sanitization.sanitize_sql_array(["name = ?", payload])

        # The fragment is a single quoted literal comparison. It matches no row,
        # but must NOT raise and must NOT drop the table.
        matches = db.query_all("SELECT name FROM victims WHERE #{fragment}", as: String)
        matches.should be_empty

        # Table and row are intact — the injection did nothing.
        db.query_one("SELECT COUNT(*) FROM victims", as: Int64).should eq 1_i64
        db.query_one("SELECT name FROM victims", as: String).should eq "safe-row"
      end
    end
  end
end
