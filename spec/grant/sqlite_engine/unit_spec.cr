require "spec"
require "../../../src/grant/sqlite_engine"

private def varint_bytes(*bytes : Int32) : Bytes
  Bytes.new(bytes.size) { |index| bytes[index].to_u8 }
end

describe Grant::SQLiteEngine::Varint do
  describe ".decode" do
    it "reads one to nine byte varints" do
      Grant::SQLiteEngine::Varint.decode(varint_bytes(0x7f), 0).should eq({127_i64, 1})
      Grant::SQLiteEngine::Varint.decode(varint_bytes(0x81, 0x00), 0).should eq({128_i64, 2})
      nine = varint_bytes(0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff)
      Grant::SQLiteEngine::Varint.decode(nine, 0).should eq({-1_i64, 9})
    end

    it "returns a length of 0 for a varint that runs past the limit" do
      Grant::SQLiteEngine::Varint.decode(varint_bytes(0x81, 0x81), 0).should eq({0_i64, 0})
      Grant::SQLiteEngine::Varint.decode(varint_bytes(0x81, 0x01), 0, 1).should eq({0_i64, 0})
    end
  end
end

describe Grant::SQLiteEngine::Record do
  describe ".decode" do
    it "decodes every serial type" do
      # header: size 9, types NULL, int8, int16, float, 0, 1, blob(1), text(2)
      payload = varint_bytes(9, 0, 1, 2, 7, 8, 9, 14, 17,
        0xff, 0x01, 0x00, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0, 0xab, 0x68, 0x69)
      Grant::SQLiteEngine::Record.decode(payload, Grant::SQLiteEngine::TextEncoding::UTF8, 2_u32)
        .should eq([nil, -1_i64, 256_i64, 1.5, 0_i64, 1_i64, Bytes[0xab], "hi"] of Grant::SQLiteEngine::Value)
    end

    it "decodes UTF-16 text to UTF-8" do
      little = varint_bytes(2, 21, 0x68, 0x00, 0xe9, 0x00)
      Grant::SQLiteEngine::Record.decode(little, Grant::SQLiteEngine::TextEncoding::UTF16LE, 2_u32).should eq(["hé"] of Grant::SQLiteEngine::Value)
      big = varint_bytes(2, 21, 0x00, 0x68, 0x00, 0xe9)
      Grant::SQLiteEngine::Record.decode(big, Grant::SQLiteEngine::TextEncoding::UTF16BE, 2_u32).should eq(["hé"] of Grant::SQLiteEngine::Value)
    end

    it "raises CorruptDatabase for reserved serial types and short bodies" do
      expect_raises(Grant::SQLiteEngine::CorruptDatabase, /serial type 10 is reserved/) do
        Grant::SQLiteEngine::Record.decode(varint_bytes(2, 10), Grant::SQLiteEngine::TextEncoding::UTF8, 3_u32)
      end
      expect_raises(Grant::SQLiteEngine::CorruptDatabase, /runs past the payload/) do
        Grant::SQLiteEngine::Record.decode(varint_bytes(2, 6, 1), Grant::SQLiteEngine::TextEncoding::UTF8, 3_u32)
      end
      expect_raises(Grant::SQLiteEngine::CorruptDatabase, /header size/) do
        Grant::SQLiteEngine::Record.decode(varint_bytes(40, 1), Grant::SQLiteEngine::TextEncoding::UTF8, 3_u32)
      end
    end
  end
end

describe Grant::SQLiteEngine::Affinity do
  describe ".from_declared_type" do
    it "follows the five rules of datatype3.html in order" do
      Grant::SQLiteEngine::Affinity.from_declared_type("BIGINT").should eq(Grant::SQLiteEngine::Affinity::Integer)
      Grant::SQLiteEngine::Affinity.from_declared_type("VARCHAR(255)").should eq(Grant::SQLiteEngine::Affinity::Text)
      Grant::SQLiteEngine::Affinity.from_declared_type("").should eq(Grant::SQLiteEngine::Affinity::Blob)
      Grant::SQLiteEngine::Affinity.from_declared_type("DOUBLE PRECISION").should eq(Grant::SQLiteEngine::Affinity::Real)
      Grant::SQLiteEngine::Affinity.from_declared_type("DECIMAL(10,2)").should eq(Grant::SQLiteEngine::Affinity::Numeric)
      Grant::SQLiteEngine::Affinity.from_declared_type("FLOATING POINT").should eq(Grant::SQLiteEngine::Affinity::Integer)
    end
  end
end

describe Grant::SQLiteEngine::TableDefinition do
  describe ".parse" do
    it "finds the rowid alias of an INTEGER PRIMARY KEY and only that" do
      Grant::SQLiteEngine::TableDefinition.parse(%(CREATE TABLE "t"( "id" INTEGER NOT NULL PRIMARY KEY, "name" VARCHAR(255) ))).rowid_alias_index.should eq(0)
      Grant::SQLiteEngine::TableDefinition.parse("CREATE TABLE t(id BIGINT PRIMARY KEY, x)").rowid_alias_index.should be_nil
      Grant::SQLiteEngine::TableDefinition.parse("CREATE TABLE t(id INTEGER PRIMARY KEY DESC, x)").rowid_alias_index.should be_nil
      Grant::SQLiteEngine::TableDefinition.parse("CREATE TABLE t(x, id INTEGER, PRIMARY KEY(id DESC))").rowid_alias_index.should eq(1)
      Grant::SQLiteEngine::TableDefinition.parse("CREATE TABLE t(id INTEGER PRIMARY KEY, x) WITHOUT ROWID").rowid_alias_index.should be_nil
    end

    it "orders a WITHOUT ROWID record with the primary key first" do
      definition = Grant::SQLiteEngine::TableDefinition.parse("CREATE TABLE t(a, b TEXT, c INTEGER, PRIMARY KEY(c, b)) WITHOUT ROWID")
      definition.without_rowid?.should be_true
      definition.stored_column_order.should eq([2, 1, 0])
    end

    it "reads defaults, generated columns and constraints" do
      definition = Grant::SQLiteEngine::TableDefinition.parse(<<-SQL)
        CREATE TABLE t(a INTEGER DEFAULT -5, b TEXT DEFAULT 'x''y', c BLOB DEFAULT x'00ff',
          d BOOLEAN DEFAULT TRUE, e TIMESTAMP DEFAULT CURRENT_TIMESTAMP, f REAL DEFAULT (1 + 1),
          g INTEGER GENERATED ALWAYS AS (a * 2) VIRTUAL, h REFERENCES t(a) ON DELETE SET NULL,
          CONSTRAINT u UNIQUE (b, c), CHECK (a > 0))
        SQL
      columns = definition.list_of_columns
      columns.map(&.default_value).first(4).should eq([-5_i64, "x'y", Bytes[0, 255], 1_i64] of Grant::SQLiteEngine::Value)
      columns[4].default_expression.should eq("CURRENT_TIMESTAMP")
      columns[5].default_expression.should eq("( 1 + 1 )")
      columns[6].generated.virtual?.should be_true
      definition.list_of_unique_constraints.should eq([["b", "c"]])
    end

    it "parses every CREATE TABLE in Grant's statement corpus" do
      corpus = Path[__DIR__] / "corpus" / "grant_sql_corpus.txt"
      creates = File.read_lines(corpus).select { |sql| sql.lstrip.upcase.starts_with?("CREATE TABLE") || sql.lstrip.upcase.starts_with?("CREATE TEMPORARY TABLE") }
      creates.size.should be > 600
      creates.each do |sql|
        definition = Grant::SQLiteEngine::TableDefinition.parse(sql)
        definition.list_of_columns.should_not be_empty
      end
    end
  end
end

describe Grant::SQLiteEngine::IndexDefinition do
  describe ".parse" do
    it "names key columns and leaves expressions nil" do
      Grant::SQLiteEngine::IndexDefinition.parse(%(CREATE INDEX i ON t("a" COLLATE NOCASE DESC, lower(b), c) WHERE c > 0))
        .list_of_key_columns.should eq(["a", nil, "c"])
    end
  end
end

describe Grant::SQLiteEngine::Database do
  describe ".from_bytes" do
    it "opens an empty file as an empty database" do
      database = Grant::SQLiteEngine::Database.from_bytes(Bytes.new(0))
      database.schema.list_of_entries.should be_empty
      database.page_count.should eq(0)
    end

    it "raises CorruptDatabase for a file that is not a database" do
      expect_raises(Grant::SQLiteEngine::CorruptDatabase, /magic string/) do
        Grant::SQLiteEngine::Database.from_bytes(Bytes.new(4096, 7_u8))
      end
    end
  end
end

describe Grant::SQLiteEngine::CorruptDatabase do
  it "names the page and the check" do
    Grant::SQLiteEngine::CorruptDatabase.new("cell 3 pointer 9 is outside", 7_u32).message
      .should eq("database disk image is malformed: page 7: cell 3 pointer 9 is outside")
  end
end

describe Grant::SQLiteEngine::Error do
  it "is the base of every engine error" do
    Grant::SQLiteEngine::UnsupportedSQL.new("x").should be_a(Grant::SQLiteEngine::Error)
    Grant::SQLiteEngine::CorruptDatabase.new("x").should be_a(Grant::SQLiteEngine::Error)
  end
end
