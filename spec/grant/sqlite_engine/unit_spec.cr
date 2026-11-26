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

# A database whose table `t` (root page 2) is a chain of *interior* interior
# table pages linked by their right children, ending in one empty leaf; when
# *last_child* is given, the last interior page points there instead (a page
# already on the path from the root) and there is no leaf.
private def database_with_chained_root(interior : Int32, last_child : UInt32? = nil) : Grant::SQLiteEngine::Database
  path = File.tempname("btree_count", ".db")
  begin
    writer = Grant::SQLiteEngine::Database.open(path, read_write: true, page_size: 512)
    writer.create_table("CREATE TABLE t (a)")
    writer.close
    bytes = File.read(path).to_slice
  ensure
    File.delete?(path)
  end
  page_size = Grant::SQLiteEngine::DatabaseHeader.page_size_from(bytes)
  page_count = 1 + interior + (last_child ? 0 : 1)
  image = Bytes.new(page_count * page_size)
  bytes[0, page_size].copy_to(image)
  IO::ByteFormat::BigEndian.encode(page_count.to_u32, image[28, 4])
  # The header's page count holds only while version-valid-for equals the
  # change counter.
  image[24, 4].copy_to(image[92, 4])
  content_start = page_size == 65536 ? 0_u16 : page_size.to_u16
  interior.times do |index|
    page = image[(index + 1) * page_size, page_size]
    page[0] = 0x05_u8
    IO::ByteFormat::BigEndian.encode(content_start, page[5, 2])
    child = index + 1 == interior && last_child ? last_child : (index + 3).to_u32
    IO::ByteFormat::BigEndian.encode(child, page[8, 4])
  end
  unless last_child
    leaf = image[(interior + 1) * page_size, page_size]
    leaf[0] = 0x0d_u8
    IO::ByteFormat::BigEndian.encode(content_start, leaf[5, 2])
  end
  Grant::SQLiteEngine::Database.from_bytes(image)
end

private def count_rows_of_t(database : Grant::SQLiteEngine::Database) : Grant::SQLiteEngine::Value
  query = Grant::SQLiteEngine::Query::Session.new(database).prepare("SELECT count(*) FROM t")
  query.step
  query.row[0]
end

describe Grant::SQLiteEngine::Query::BTreeCount do
  describe ".entries" do
    it "counts the rows below a chain of interior pages" do
      count_rows_of_t(database_with_chained_root(3)).should eq(0_i64)
    end

    it "raises CorruptDatabase for a child already on the path from the root" do
      expect_raises(Grant::SQLiteEngine::CorruptDatabase, /reaches the page twice/) do
        count_rows_of_t(database_with_chained_root(3, last_child: 3_u32))
      end
    end

    it "raises CorruptDatabase for a tree deeper than MAX_BTREE_DEPTH" do
      depth = Grant::SQLiteEngine::Limits::MAX_BTREE_DEPTH
      count_rows_of_t(database_with_chained_root(depth - 1)).should eq(0_i64)
      expect_raises(Grant::SQLiteEngine::CorruptDatabase, /deeper than #{depth} pages/) do
        count_rows_of_t(database_with_chained_root(depth))
      end
    end
  end
end

# A session on a fresh database holding tables `u` (rowid alias `id`) and
# `p` (rows of `u` by `u_id`) with a few rows.
private def session_with_users_and_posts : Grant::SQLiteEngine::Query::Session
  path = File.tempname("shared_lists", ".db")
  database = Grant::SQLiteEngine::Database.open(path, read_write: true)
  session = Grant::SQLiteEngine::Query::Session.new(database)
  ["CREATE TABLE u (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)",
   "CREATE TABLE p (id INTEGER PRIMARY KEY, u_id INTEGER, title TEXT)",
   "CREATE INDEX p_u ON p (u_id)",
   "INSERT INTO u VALUES (1, 'ann', 30), (2, 'bob', 40), (3, 'cy', 50)",
   "INSERT INTO p (u_id, title) VALUES (1, 'a'), (1, 'b'), (2, 'c')"].each do |sql|
    query = session.prepare(sql)
    while query.step
    end
  end
  session
end

private def rows_of(session : Grant::SQLiteEngine::Query::Session, sql : String) : Array(Array(Grant::SQLiteEngine::Value))
  query = session.prepare(sql)
  list_of_rows = [] of Array(Grant::SQLiteEngine::Value)
  while query.step
    list_of_rows << query.row.dup
  end
  list_of_rows
end

describe Grant::SQLiteEngine::Query::Compiler do
  it "names result columns by alias, column name, then source text" do
    session = session_with_users_and_posts
    query = session.prepare("SELECT u.name, age AS years,  age + 1 , upper( name ) FROM u WHERE id = ?")
    query.list_of_column_names.should eq(["name", "years", "age + 1", "upper( name )"])
  end

  it "leaves the shared empty lists empty after a mix of statements" do
    session = session_with_users_and_posts
    rows_of(session, "SELECT name FROM u WHERE id = 2").should eq([["bob"]])
    rows_of(session, "SELECT u.name, count(p.id) FROM u LEFT JOIN p ON p.u_id = u.id GROUP BY u.id ORDER BY u.id")
      .should eq([["ann", 2_i64], ["bob", 1_i64], ["cy", 0_i64]])
    rows_of(session, "SELECT name FROM u WHERE age > 35 UNION ALL SELECT title FROM p WHERE u_id = 1")
      .should eq([["bob"], ["cy"], ["a"], ["b"]])
    rows_of(session, "SELECT EXISTS (SELECT 1 FROM p WHERE p.u_id = u.id) FROM u ORDER BY id")
      .should eq([[1_i64], [1_i64], [0_i64]])
    rows_of(session, "SELECT * FROM u, p WHERE p.u_id = u.id AND p.title = 'c'")
      .should eq([[2_i64, "bob", 40_i64, 3_i64, 2_i64, "c"]])
    rows_of(session, "SELECT count(*) FROM p").should eq([[3_i64]])
    Grant::SQLiteEngine::Query::Frame::NO_ROW_YET.should be_empty
    Grant::SQLiteEngine::Query::Frame::NO_AGGREGATE_VALUES.should be_empty
    Grant::SQLiteEngine::Query::Compiler::NO_SORT_KEYS.should be_empty
    Grant::SQLiteEngine::Query::Compiler::NO_UNKNOWN_COLLATIONS.should be_empty
    Grant::SQLiteEngine::Query::Compiler::NO_EXPRESSIONS.should be_empty
    Grant::SQLiteEngine::Query::Compiler::NO_ORDERING.should be_empty
    Grant::SQLiteEngine::SQL::Parser::NO_COMPOUND_OPERATORS.should be_empty
    Grant::SQLiteEngine::SQL::Parser::NO_EXPRESSIONS.should be_empty
    Grant::SQLiteEngine::SQL::Parser::NO_WINDOWS.should be_empty
    Grant::SQLiteEngine::SQL::Parser::NO_ORDERING_TERMS.should be_empty
  end
end
