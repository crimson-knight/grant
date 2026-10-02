require "big"
require "../../support/schema_fixture"
require "../../support/test_connection"

class M02aTypedRow < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table m02a_typed_rows

  column id : Int64, primary: true
  column code : String?, limit: 20
  column note : String?
  column happened : Time?, precision: 3
  column ratio : Float64?
  column flag : Bool?
end

# Every column kind of the DSL, in the order the SQL expectations list them.
private def m02a_kinds(t : Grant::Schema::TableDefinition) : Nil
  t.string :s
  t.string :s_limited, limit: 40
  t.text :body
  t.integer :i
  t.integer :i_limited, limit: 2
  t.smallint :sm
  t.tinyint :ti
  t.bigint :bi
  t.boolean :flag
  t.float :f
  t.double :d
  t.decimal :price, precision: 12, scale: 2
  t.datetime :at
  t.datetime :at3, precision: 3
  t.date :on
  t.time :of
  t.binary :bytes
  t.json :doc
  t.uuid :ident
end

describe "Schema type mapping" do
  describe "DSL types in every dialect" do
    {
      Grant::Schema::Dialect::Pg => [
        %("s" VARCHAR), %("s_limited" VARCHAR(40)), %("body" TEXT), %("i" INTEGER), %("i_limited" SMALLINT),
        %("sm" SMALLINT), %("ti" SMALLINT), %("bi" BIGINT), %("flag" BOOLEAN), %("f" REAL), %("d" DOUBLE PRECISION),
        %("price" NUMERIC(12, 2)), %("at" TIMESTAMP(6)), %("at3" TIMESTAMP(3)), %("on" DATE), %("of" TIME(6)),
        %("bytes" BYTEA), %("doc" JSON), %("ident" UUID),
      ],
      Grant::Schema::Dialect::Mysql => [
        "`s` VARCHAR(255)", "`s_limited` VARCHAR(40)", "`body` TEXT", "`i` INT", "`i_limited` SMALLINT",
        "`sm` SMALLINT", "`ti` TINYINT", "`bi` BIGINT", "`flag` TINYINT(1)", "`f` FLOAT", "`d` DOUBLE",
        "`price` DECIMAL(12, 2)", "`at` DATETIME(6)", "`at3` DATETIME(3)", "`on` DATE", "`of` TIME(6)",
        "`bytes` BLOB", "`doc` JSON", "`ident` CHAR(36)",
      ],
      Grant::Schema::Dialect::Sqlite => [
        %("s" VARCHAR(255)), %("s_limited" VARCHAR(40)), %("body" TEXT), %("i" INTEGER), %("i_limited" SMALLINT),
        %("sm" SMALLINT), %("ti" TINYINT), %("bi" BIGINT), %("flag" BOOLEAN), %("f" FLOAT), %("d" REAL),
        %("price" NUMERIC(12, 2)), %("at" DATETIME), %("at3" DATETIME), %("on" DATE), %("of" TIME),
        %("bytes" BLOB), %("doc" JSON), %("ident" CHAR(36)),
      ],
    }.each do |dialect, columns|
      it "maps every kind on #{dialect}" do
        sql = Grant::Schema::RecordingStatements.new(dialect).create_table_statements(:m02a_kinds, id: false) { |t| m02a_kinds(t) }.first
        columns.each { |column| sql.should contain(column) }
      end
    end

    it "picks MySQL text and blob sizes from limit" do
      dialect = Grant::Schema::Dialect::Mysql
      sql = Grant::Schema::RecordingStatements.new(dialect).create_table_statements(:sized, id: false) do |t|
        t.text :a, limit: 100
        t.text :b, limit: 70_000
        t.text :c, limit: 20_000_000
        t.binary :d, limit: 200
        t.integer :e, limit: 3
      end.first
      sql.should contain "`a` TINYTEXT"
      sql.should contain "`b` MEDIUMTEXT"
      sql.should contain "`c` LONGTEXT"
      sql.should contain "`d` TINYBLOB"
      sql.should contain "`e` MEDIUMINT"
    end

    it "rejects jsonb outside PostgreSQL and scale without precision" do
      expect_raises(Grant::Schema::UnsupportedOperation) do
        Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).create_table_statements(:a) { |t| t.jsonb :doc }
      end
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).create_table_statements(:a, id: false) { |t| t.jsonb :doc }.first.should contain "\"doc\" JSONB"
      expect_raises(Grant::Schema::InvalidDefinition) do
        Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).create_table_statements(:a) { |t| t.decimal :x, scale: 2 }
      end
    end
  end

  describe "Crystal type catalog" do
    it "maps Int8, Int16, Bytes, Date, JSON::Any and BigDecimal per dialect" do
      pg = Grant::Schema::TypeCatalog::PG
      pg["Int8"].should eq "SMALLINT"
      pg["Bytes"].should eq "BYTEA"
      pg["JSON::Any"].should eq "JSONB"
      Grant::Schema::TypeCatalog::MYSQL["Int8"].should eq "TINYINT"
      Grant::Schema::TypeCatalog::MYSQL["JSON::Any"].should eq "JSON"
      Grant::Schema::TypeCatalog::SQLITE["Bytes"].should eq "BLOB"
    end

    it "refines BigDecimal by precision and scale and Time by precision" do
      refine = ->(dialect : Grant::Schema::Dialect, key : String, base : String) do
        Grant::Schema::TypeCatalog.refine(dialect, key, base, nil, key == "Time" ? 3 : 12, key == "Time" ? nil : 2)
      end
      refine.call(Grant::Schema::Dialect::Pg, "BigDecimal", "NUMERIC").should eq "NUMERIC(12, 2)"
      refine.call(Grant::Schema::Dialect::Mysql, "BigDecimal", "DECIMAL").should eq "DECIMAL(12, 2)"
      refine.call(Grant::Schema::Dialect::Pg, "Time", "TIMESTAMP").should eq "TIMESTAMP(3)"
      refine.call(Grant::Schema::Dialect::Mysql, "Time", "TIMESTAMP(6)").should eq "TIMESTAMP(3)"
      refine.call(Grant::Schema::Dialect::Sqlite, "Time", "TIMESTAMP").should eq "TIMESTAMP"
      Grant::Schema::TypeCatalog.refine(Grant::Schema::Dialect::Pg, "String", "TEXT", 30).should eq "VARCHAR(30)"
      Grant::Schema::TypeCatalog.refine(Grant::Schema::Dialect::Pg, "String", "TEXT").should eq "TEXT"
    end
  end

  describe "model columns on #{CURRENT_ADAPTER}" do
    before_each do
      TestConnection.ensure_registered
      M02aTypedRow.migrator.drop_and_create
    end

    after_all { M02aTypedRow.migrator.drop }

    it "emits limit and precision in the create SQL" do
      sql = M02aTypedRow.migrator.create_sql
      case CURRENT_ADAPTER
      when "pg"
        sql.should contain %("code" VARCHAR(20))
        sql.should contain %("note" TEXT)
        sql.should contain %("happened" TIMESTAMP(3))
      when "mysql"
        sql.should contain "`code` VARCHAR(20)"
        sql.should contain "`note` VARCHAR(255)"
        sql.should contain "`happened` TIMESTAMP(3)"
      else
        sql.should contain %("code" VARCHAR(20))
        sql.should contain %("note" VARCHAR(255))
        sql.should contain %("happened" TIMESTAMP)
      end
    end

    it "round trips values through the created table" do
      row = M02aTypedRow.new
      row.code = "abc"
      row.note = "text"
      row.happened = Time.utc(2020, 1, 2, 3, 4, 5, nanosecond: 123_000_000)
      row.ratio = 1.5
      row.flag = true
      row.save!

      found = M02aTypedRow.find!(row.id)
      found.code.should eq "abc"
      found.note.should eq "text"
      found.happened.not_nil!.to_utc.to_unix_ms.should eq Time.utc(2020, 1, 2, 3, 4, 5, nanosecond: 123_000_000).to_unix_ms
      found.ratio.should eq 1.5
      found.flag.should be_true
    end
  end

  describe "DSL table on #{CURRENT_ADAPTER}" do
    statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)

    after_all { statements.drop_table(:m02a_kinds, if_exists: true) }

    it "creates every kind, inserts and reads the values back" do
      statements.drop_table(:m02a_kinds, if_exists: true)
      statements.create_table(:m02a_kinds) do |t|
        t.tinyint :ti
        t.smallint :sm
        t.decimal :price, precision: 12, scale: 2
        t.binary :bytes
        t.date :on
        t.text :body
        t.string :s_limited, limit: 5
        t.datetime :at
        t.json :doc
      end
      adapter = SchemaFixture.adapter
      adapter.open do |db|
        quote = CURRENT_ADAPTER == "mysql" ? "`" : "\""
        placeholder = CURRENT_ADAPTER == "pg" ? "$1" : "?"
        db.exec "INSERT INTO m02a_kinds (ti, sm, price, bytes, #{quote}on#{quote}, body, s_limited, #{quote}at#{quote}, doc) " \
                "VALUES (5, 300, 12345.67, #{placeholder}, '2020-01-02', 'long text', 'abcde', '2020-01-02 03:04:05', '{\"a\":1}')", args: [Bytes[1, 2, 255]]
        db.query(%(SELECT ti, sm, price, bytes, body, s_limited FROM m02a_kinds)) do |rs|
          rs.move_next.should be_true
          rs.read.to_s.should eq "5"
          rs.read.to_s.should eq "300"
          rs.read.to_s.should eq "12345.67"
          rs.read.to_s.should eq "Bytes[1, 2, 255]"
          rs.read.to_s.should eq "long text"
          rs.read.to_s.should eq "abcde"
        end
      end
      columns = adapter.schema.columns(:m02a_kinds).index_by(&.name)
      columns["price"].precision.should eq 12
      columns["price"].scale.should eq 2
      columns["s_limited"].limit.should eq 5
      columns["body"].type_family.should eq Grant::Schema::TypeFamily::Text
    end

    it "enforces a varchar limit where the database does" do
      next if CURRENT_ADAPTER == "sqlite" # SQLite does not enforce VARCHAR(n)
      statements.drop_table(:m02a_kinds, if_exists: true)
      statements.create_table(:m02a_kinds) { |t| t.string :s_limited, limit: 3 }
      expect_raises(Grant::ErrorBase) do
        SchemaFixture.adapter.open { |db| db.exec "INSERT INTO m02a_kinds (s_limited) VALUES ('toolong')" }
      end
    end
  end
end
