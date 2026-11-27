require "spec"
require "../../support/sqlite_engine/crash_file"

private alias Engine = Grant::SQLiteEngine

private def values(*list) : Array(Engine::Value)
  list.to_a.map(&.as(Engine::Value))
end

private def temporary_database(name : String) : String
  directory = Path[Dir.tempdir] / "grant-sqlite-engine-writes-#{Process.pid}"
  Dir.mkdir_p(directory)
  path = (directory / "#{name}.db").to_s
  File.delete?(path)
  File.delete?("#{path}-journal")
  path
end

private def sqlite3(path : String, sql : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run("sqlite3", [path, sql], output: output, error: error)
  raise "sqlite3 failed: #{error}" unless status.success?
  output.to_s
end

describe Engine::RecordEncoder do
  it "stores each integer in the fewest bytes and 0 and 1 in the header" do
    list = values(0_i64, 1_i64, 127_i64, -129_i64, 8_388_607_i64, 2_147_483_648_i64, 140_737_488_355_328_i64, nil, 1.5, "hi", Bytes[1, 2])
    record = Engine::RecordEncoder.encode(list, Engine::TextEncoding::UTF8)
    record[0, 12].should eq(Bytes[12, 8, 9, 1, 2, 3, 5, 6, 0, 7, 17, 16])
    Engine::Record.decode(record, Engine::TextEncoding::UTF8, 2_u32).should eq(list)
  end

  it "writes text in the database encoding" do
    little = Engine::RecordEncoder.encode(values("hé"), Engine::TextEncoding::UTF16LE)
    little.should eq(Bytes[2, 21, 0x68, 0x00, 0xe9, 0x00])
    Engine::Record.decode(little, Engine::TextEncoding::UTF16LE, 2_u32).should eq(values("hé"))
  end

  it "encodes into a reused buffer the bytes it encodes alone, growing it for a larger record" do
    buffer = Engine::RecordEncoder::EncodeBuffer.new
    [values(1_i64, "a", nil), values("x" * 600, 2.5, Bytes[7]), values(-3_i64, Float64::NAN), values("hé", 0_i64)].each do |list|
      {Engine::TextEncoding::UTF8, Engine::TextEncoding::UTF16BE}.each do |encoding|
        alone = Engine::RecordEncoder.encode(list, encoding)
        Engine::RecordEncoder.encode(list.size, encoding, 4_u32, buffer) { |index| list[index] }.should eq(alone)
      end
    end
  end
end

describe Engine::BTreeScratch do
  it "lends distinct buffers within a change and the same ones to the next change" do
    scratch = Engine::BTreeScratch.new
    mark = scratch.mark
    first = scratch.page(4096)
    second = scratch.page(100)
    first.to_unsafe.should_not eq(second.to_unsafe)
    list = scratch.cell_list
    list << first[0, 4]
    scratch.release(mark)
    scratch.page(4096).to_unsafe.should eq(first.to_unsafe)
    scratch.page(64).to_unsafe.should eq(second.to_unsafe)
    scratch.cell_list.should be_empty
  end
end

describe Engine::StoredValue do
  it "applies column affinity as SQLite stores values" do
    Engine::StoredValue.for_affinity(Engine::Affinity::Integer, " 12 ").should eq(12_i64)
    Engine::StoredValue.for_affinity(Engine::Affinity::Numeric, "1e3").should eq(1000_i64)
    Engine::StoredValue.for_affinity(Engine::Affinity::Numeric, "1.5").should eq(1.5)
    Engine::StoredValue.for_affinity(Engine::Affinity::Integer, 3.0).should eq(3_i64)
    Engine::StoredValue.for_affinity(Engine::Affinity::Real, 3.0).should eq(3_i64)
    Engine::StoredValue.for_affinity(Engine::Affinity::Real, 2.0 ** 50).should eq(2.0 ** 50)
    Engine::StoredValue.for_affinity(Engine::Affinity::Text, 5_i64).should eq("5")
    Engine::StoredValue.for_affinity(Engine::Affinity::Blob, "5").should eq("5")
    Engine::StoredValue.for_affinity(Engine::Affinity::Integer, "abc").should eq("abc")
  end

  it "raises a datatype constraint for STRICT columns" do
    expect_raises(Engine::ConstraintViolation, "cannot store TEXT value in INTEGER column t.c") do
      Engine::StoredValue.for_strict_column("INTEGER", "t.c", "abc")
    end
    Engine::StoredValue.for_strict_column("INTEGER", "c", "12").should eq(12_i64)
  end
end

describe "Grant::SQLiteEngine writes" do
  it "creates a database the sqlite3 tool reads, with integrity_check ok" do
    path = temporary_database("round_trip")
    database = Engine::Database.open(path, read_write: true)
    database.create_table("CREATE TABLE IF NOT EXISTS main.people(id INTEGER PRIMARY KEY, name TEXT, score REAL, avatar BLOB);")
    database.create_table("CREATE TABLE IF NOT EXISTS people(x)").should be_false
    database.insert("people", nil, values(nil, "Ada", 1.5, Bytes[0, 255])).should eq(1_i64)
    database.insert("people", nil, values(nil, "Grace", 2_i64, nil)).should eq(2_i64)
    database.insert("people", 10_i64, values(nil, "x" * 10_000, nil, nil)).should eq(10_i64)
    database.close
    sqlite3(path, "PRAGMA integrity_check;").should eq("ok\n")
    sqlite3(path, "SELECT id, name, typeof(score), score FROM people WHERE id < 10;").should eq("1|Ada|real|1.5\n2|Grace|real|2.0\n")
    sqlite3(path, "SELECT length(name) FROM people WHERE id = 10;").should eq("10000\n")
    sqlite3(path, "SELECT sql FROM sqlite_schema;").should eq("CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT, score REAL, avatar BLOB)\n")
    reader = Engine::Database.open(path)
    reader.rows("people").map(&.values[1]).should eq(values("Ada", "Grace", "x" * 10_000))
    reader.close
  end

  it "splits, merges and frees pages through many inserts and deletes" do
    path = temporary_database("splits")
    database = Engine::Database.open(path, read_write: true, page_size: 512)
    database.create_table("CREATE TABLE t(a INTEGER, b TEXT, c BLOB)")
    database.create_index("CREATE INDEX t_b ON t(b COLLATE NOCASE DESC, a)")
    database.create_index("CREATE UNIQUE INDEX t_a ON t(a)")
    random = Random.new(7)
    database.transaction do |writer|
      2_000.times do |number|
        writer.insert("t", nil, values(number.to_i64, "row #{random.rand(1000)} #{"y" * random.rand(300)}", Bytes.new(random.rand(2_000), 7_u8)))
      end
    end
    database.transaction do |writer|
      (1_i64..2_000_i64).each { |rowid| writer.delete("t", rowid) if rowid % 3 != 0 }
    end
    expect_raises(Engine::ConstraintViolation, /UNIQUE/) do
      database.insert("t", nil, values(2_i64, "dup", nil))
    end
    database.close
    sqlite3(path, "PRAGMA integrity_check;").should eq("ok\n")
    sqlite3(path, "SELECT count(*), sum(a) FROM t;").should eq("666|#{(1..666).sum { |n| n * 3 - 1 }}\n")
  end

  it "deletes rows by rowid in a table without indexes as C does: the same rows, pages and freelist, overflow pages and emptied leaves included" do
    path = temporary_database("deletes_without_indexes")
    database = Engine::Database.open(path, read_write: true, page_size: 512)
    database.create_table("CREATE TABLE t(id INTEGER PRIMARY KEY, label TEXT, body BLOB)")
    database.transaction do |writer|
      (1_i64..1_500_i64).each do |number|
        writer.insert("t", nil, values(nil, "label #{number}", Bytes.new(number % 11 == 0 ? 1_800 : (number % 90).to_i32, 3_u8)))
      end
    end
    database.close
    c_path = "#{path}.c.db"
    File.copy(path, c_path)
    list_of_deletes = (1_i64..1_600_i64).to_a.shuffle(Random.new(11)).first(1_100)
    database = Engine::Database.open(path, read_write: true)
    database.transaction do |writer|
      list_of_deletes.each { |rowid| writer.delete("t", rowid).should eq(rowid <= 1_500) }
    end
    database.delete("t", 1_501_i64).should be_false
    database.close
    # On sqlite3's input: 1,100 statements are past the length of a Windows command line.
    deletes_sql = IO::Memory.new("BEGIN;\n" + list_of_deletes.map { |rowid| "DELETE FROM t WHERE rowid = #{rowid};\n" }.join + "COMMIT;\n")
    Process.run("sqlite3", [c_path], input: deletes_sql).success?.should be_true
    check = "PRAGMA integrity_check; PRAGMA page_count; PRAGMA freelist_count; SELECT count(*), sum(id), sum(length(body)) FROM t;"
    sqlite3(path, check).should eq(sqlite3(c_path, check))
    sqlite3(path, "PRAGMA integrity_check;").should eq("ok\n")
  end

  it "maintains index entries on update and keeps nothing of a failed statement" do
    path = temporary_database("updates")
    database = Engine::Database.open(path, read_write: true)
    database.create_table("CREATE TABLE t(id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, n)")
    database.insert("t", nil, values(nil, "a@example.com", 1_i64))
    database.insert("t", nil, values(nil, "b@example.com", 2_i64))
    database.update("t", 1_i64, values(5_i64, "c@example.com", 3_i64)).should be_true
    expect_raises(Engine::ConstraintViolation, /NOT NULL/) { database.insert("t", nil, values(nil, nil, 4_i64)) }
    expect_raises(Engine::ConstraintViolation, /UNIQUE/) { database.update("t", 2_i64, values(2_i64, "c@example.com", 9_i64)) }
    database.delete("t", 99_i64).should be_false
    database.close
    sqlite3(path, "PRAGMA integrity_check;").should eq("ok\n")
    sqlite3(path, "SELECT id, email, n FROM t ORDER BY id;").should eq("2|b@example.com|2\n5|c@example.com|3\n")
  end

  it "replaces rows in place in a table without indexes, keeping the rest of the transaction after a refused update" do
    path = temporary_database("updates_in_place")
    database = Engine::Database.open(path, read_write: true, page_size: 512)
    database.create_table("CREATE TABLE t(id INTEGER PRIMARY KEY, label TEXT NOT NULL, n)")
    database.create_table("CREATE TABLE u(a, b)")
    database.transaction do |writer|
      (1_i64..300_i64).each do |number|
        writer.insert("t", nil, values(nil, "label #{number}", number))
        writer.insert("u", nil, values(number, "b #{number}"))
      end
    end
    database.transaction do |writer|
      (1_i64..300_i64).each do |number|
        label = number % 7 == 0 ? "long #{"z" * 2_000}" : (number.even? ? "l#{number}" : "longer label #{number} #{"y" * 40}")
        writer.update("t", number, values(number.odd? ? number : nil, label, number * 2)).should be_true
      end
      writer.update("t", 301_i64, values(nil, "absent", 0_i64)).should be_false
      writer.update("t", 301_i64, values(nil, nil, 0_i64)).should be_false
      writer.update("t", 301_i64, values(nil, "short")).should be_false
      expect_raises(Engine::ConstraintViolation, /NOT NULL/) { writer.update("t", 5_i64, values(nil, nil, 0_i64)) }
      expect_raises(Engine::ConstraintViolation, /datatype mismatch/) { writer.update("t", 6_i64, values("six", "x", 0_i64)) }
      writer.update("u", 10_i64, values(10_i64, "changed")).should be_true
    end
    database.update("t", 3_i64, values(400_i64, "moved", 0_i64)).should be_true
    database.update("t", 4_i64, values(4_i64, "kept", 1_i64)).should be_true
    database.close
    sqlite3(path, "PRAGMA integrity_check;").should eq("ok\n")
    sqlite3(path, "SELECT count(*), sum(n) FROM t;").should eq("300|#{(1..300).sum { |number| number * 2 } - 6 - 8 + 1}\n")
    sqlite3(path, "SELECT id, label, n FROM t WHERE id IN (2, 3, 4, 5, 400) ORDER BY id;").should eq(
      "2|l2|4\n4|kept|1\n5|longer label 5 #{"y" * 40}|10\n400|moved|0\n")
    sqlite3(path, "SELECT length(label) FROM t WHERE id = 7;").should eq("#{5 + 2_000}\n")
    sqlite3(path, "SELECT rowid, a, b FROM u WHERE rowid IN (9, 10) ORDER BY rowid;").should eq("9|9|b 9\n10|10|changed\n")
  end

  it "rolls a transaction back" do
    path = temporary_database("rollback")
    database = Engine::Database.open(path, read_write: true)
    database.create_table("CREATE TABLE t(a)")
    database.transaction do |writer|
      writer.insert("t", nil, values(1_i64))
      raise Engine::Rollback.new
    end
    database.rows("t").should be_empty
    database.close
    File.exists?("#{path}-journal").should be_false
  end

  it "assigns the hidden rowid for BIGINT PRIMARY KEY and the key itself for INTEGER PRIMARY KEY" do
    path = temporary_database("bigint_key")
    database = Engine::Database.open(path, read_write: true)
    database.create_table("CREATE TABLE big(id BIGINT PRIMARY KEY, v)")
    database.create_table("CREATE TABLE int(id INTEGER PRIMARY KEY AUTOINCREMENT, v)")
    database.insert("big", nil, values(500_i64, "a")).should eq(1_i64)
    database.insert("int", nil, values(500_i64, "a")).should eq(500_i64)
    database.insert("int", nil, values(nil, "b")).should eq(501_i64)
    database.close
    sqlite3(path, "PRAGMA integrity_check; SELECT rowid, id FROM big; SELECT name, seq FROM sqlite_sequence;").should eq("ok\n1|500\nint|501\n")
  end

  it "reports Busy while the sqlite3 tool holds the write lock" do
    path = temporary_database("busy")
    sqlite3(path, "CREATE TABLE t(a);")
    holder = Process.new("sqlite3", [path], input: :pipe, output: :pipe, error: :pipe)
    input = holder.input
    input.puts "BEGIN IMMEDIATE; INSERT INTO t VALUES (1); SELECT 'locked';"
    input.flush
    holder.output.gets.should eq("locked")
    database = Engine::Database.open(path, read_write: true)
    expect_raises(Engine::Busy) { database.insert("t", nil, values(2_i64)) }
    input.puts "COMMIT;"
    input.close
    holder.wait
    database.insert("t", nil, values(3_i64))
    database.rows("t").map(&.values[0]).should eq(values(1_i64, 3_i64))
    database.close
    sqlite3(path, "INSERT INTO t VALUES (4); SELECT count(*) FROM t;").should eq("3\n")
  end

  it "reads the sqlite3 tool's commits made after it opened the file" do
    path = temporary_database("interop")
    database = Engine::Database.open(path, read_write: true)
    database.create_table("CREATE TABLE t(a)")
    database.insert("t", nil, values(1_i64))
    sqlite3(path, "INSERT INTO t VALUES (2); CREATE TABLE u(b); INSERT INTO u VALUES ('x');")
    database.rows("t").size.should eq(2)
    database.insert("u", nil, values("y"))
    database.rows("u").map(&.values[0]).should eq(values("x", "y"))
    database.close
    sqlite3(path, "PRAGMA integrity_check; SELECT count(*) FROM u;").should eq("ok\n2\n")
  end

  it "rolls back a hot journal a crash left behind" do
    file_system = SQLiteEngineCrashFileSystem.new
    database = Engine::Database.open("crash.db", read_write: true, file_system: file_system)
    database.create_table("CREATE TABLE t(a)")
    database.insert("t", nil, values(1_i64))
    before = file_system.snapshot
    file_system.start_recording
    database.insert("t", nil, values(2_i64))
    operations = file_system.stop_recording
    database.close
    delete_at = operations.index(&.kind.delete?) || raise "the commit deleted no journal"
    state = SQLiteEngineCrashFileSystem.crash_state(before, operations, delete_at, SQLiteEngineCrashFileSystem::Variant::Kept) || raise "no crash state"
    state.has_key?("crash.db-journal").should be_true
    recovered = Engine::Database.open("crash.db", read_write: true, file_system: SQLiteEngineCrashFileSystem.new(state))
    recovered.rows("t").map(&.values[0]).should eq(values(1_i64))
    recovered.close
  end

  it "writes a database C left in WAL mode, in WAL mode" do
    path = temporary_database("wal")
    sqlite3(path, "PRAGMA journal_mode=WAL; CREATE TABLE t(a);")
    database = Engine::Database.open(path, read_write: true)
    database.insert("t", nil, values(1_i64))
    database.close
    sqlite3(path, "PRAGMA journal_mode; SELECT a FROM t;").should eq("wal\n1\n")
  end
end
