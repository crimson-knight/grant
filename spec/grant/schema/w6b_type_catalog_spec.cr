require "big"
require "../../support/test_connection"

class W6bCatalogRow < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_catalog_rows

  column id : Int64, primary: true
  column tiny : Int8?
  column small : Int16?
  column narrow : Int32?, limit: 2
  column wide : Int32?, limit: 8
  column blob : Bytes?, limit: 100
  column doc : JSON::Any?
  column code : String?, limit: 12
  column amount : BigDecimal?, precision: 10, scale: 3
  column seen_at : Time?, precision: 3
  column notes : String?
end

# Verbatim native types: the SQL is the same on every adapter's model.
class W6bNativeRow < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_native_rows

  column id : Int64, primary: true
  column email : String?, column_type: "citext"
  column attrs : String?, column_type: "hstore"
  column path : String?, column_type: "ltree"
  column address : String?, column_type: "inet"
  column price : String?, column_type: "money"
end

describe "Schema type catalog on #{CURRENT_ADAPTER}" do
  pg = Grant::Schema::Dialect::Pg
  mysql = Grant::Schema::Dialect::Mysql
  sqlite = Grant::Schema::Dialect::Sqlite

  describe "limit on integer and binary columns" do
    it "maps the byte width to the dialect's integer type" do
      limits = {1 => {"SMALLINT", "TINYINT", "TINYINT"}, 2 => {"SMALLINT", "SMALLINT", "SMALLINT"},
                3 => {"INTEGER", "MEDIUMINT", "INTEGER"}, 4 => {"INTEGER", "INT", "INTEGER"},
                8 => {"BIGINT", "BIGINT", "BIGINT"}}
      limits.each do |limit, (on_pg, on_mysql, on_sqlite)|
        Grant::Schema::TypeCatalog.refine(pg, "Int32", "INTEGER", limit).should eq on_pg
        Grant::Schema::TypeCatalog.refine(mysql, "Int32", "INT", limit).should eq on_mysql
        Grant::Schema::TypeCatalog.refine(sqlite, "Int64", "INTEGER", limit).should eq on_sqlite
      end
      Grant::Schema::TypeCatalog.refine(pg, "Int32", "INTEGER").should eq "INTEGER"
      expect_raises(Grant::Schema::InvalidDefinition) { Grant::Schema::TypeCatalog.refine(mysql, "Int32", "INT", 9) }
    end

    it "sizes MySQL blobs by limit and leaves other dialects alone" do
      Grant::Schema::TypeCatalog.refine(mysql, "Bytes", "BLOB", 200).should eq "TINYBLOB"
      Grant::Schema::TypeCatalog.refine(mysql, "Bytes", "BLOB", 70_000).should eq "MEDIUMBLOB"
      Grant::Schema::TypeCatalog.refine(mysql, "Bytes", "BLOB").should eq "BLOB"
      Grant::Schema::TypeCatalog.refine(pg, "Bytes", "BYTEA", 200).should eq "BYTEA"
    end
  end

  describe "Crystal type for a native type" do
    it "maps PostgreSQL native types, including the extension types" do
      {
        "smallint" => "Int16", "integer" => "Int32", "bigint" => "Int64", "numeric(12, 2)" => "BigDecimal",
        "character varying(20)" => "String", "text" => "String", "bytea" => "Bytes", "boolean" => "Bool",
        "timestamp(6) without time zone" => "Time", "jsonb" => "JSON::Any", "uuid" => "UUID",
        "integer[]" => "Array(Int32)", "text[]" => "Array(String)",
        "citext" => "String", "hstore" => "String", "ltree" => "String", "inet" => "String", "money" => "String",
      }.each do |native, crystal|
        Grant::Schema::TypeCatalog.crystal_type(pg, native).should eq crystal
      end
      Grant::Schema::TypeCatalog.crystal_type(pg, "no_such_type").should be_nil
    end

    it "maps MySQL and SQLite native types" do
      Grant::Schema::TypeCatalog.crystal_type(mysql, "tinyint(1)").should eq "Bool"
      Grant::Schema::TypeCatalog.crystal_type(mysql, "decimal(12,2)").should eq "BigDecimal"
      Grant::Schema::TypeCatalog.crystal_type(mysql, "json").should eq "JSON::Any"
      Grant::Schema::TypeCatalog.crystal_type(sqlite, "VARCHAR(255)").should eq "String"
      Grant::Schema::TypeCatalog.crystal_type(sqlite, "BLOB").should eq "Bytes"
      Grant::Schema::TypeCatalog.crystal_type(sqlite, "NUMERIC(10, 2)").should eq "BigDecimal"
    end

    it "names the extension a PostgreSQL type needs" do
      Grant::Schema::TypeCatalog.extension_for("hstore").should eq "hstore"
      Grant::Schema::TypeCatalog.extension_for("citext").should eq "citext"
      Grant::Schema::TypeCatalog.extension_for("LTREE").should eq "ltree"
      Grant::Schema::TypeCatalog.extension_for("jsonb").should be_nil
    end
  end

  describe "model with a column of every Crystal type" do
    before_each do
      TestConnection.ensure_registered
      W6bCatalogRow.migrator.drop_and_create
    end

    after_all { W6bCatalogRow.migrator.drop }

    it "emits the refined native types" do
      sql = W6bCatalogRow.migrator.create_sql
      case CURRENT_ADAPTER
      when "pg"
        sql.should contain %("tiny" SMALLINT)
        sql.should contain %("narrow" SMALLINT)
        sql.should contain %("wide" BIGINT)
        sql.should contain %("blob" BYTEA)
        sql.should contain %("doc" JSONB)
        sql.should contain %("amount" NUMERIC(10, 3))
      when "mysql"
        sql.should contain "`tiny` TINYINT"
        sql.should contain "`narrow` SMALLINT"
        sql.should contain "`blob` TINYBLOB"
        sql.should contain "`doc` JSON"
        sql.should contain "`amount` DECIMAL(10, 3)"
      else
        sql.should contain %("tiny" INTEGER)
        sql.should contain %("narrow" SMALLINT)
        sql.should contain %("wide" BIGINT)
        sql.should contain %("blob" BLOB)
        sql.should contain %("doc" TEXT)
        sql.should contain %("amount" NUMERIC(10, 3))
      end
      sql.should contain "VARCHAR(12)"
    end

    it "round trips every type through the created table" do
      stamp = Time.utc(2020, 1, 2, 3, 4, 5, nanosecond: 123_000_000)
      row = W6bCatalogRow.create!(tiny: 12_i8, small: 31_000_i16, narrow: 300, wide: 50_000_000,
        blob: Bytes[0, 1, 2, 255], doc: JSON.parse(%({"a":[1,2],"b":"x"})), code: "abc",
        amount: BigDecimal.new("1234567.891"), seen_at: stamp, notes: "n")

      found = W6bCatalogRow.find!(row.id)
      found.tiny.should eq 12_i8
      found.small.should eq 31_000_i16
      found.narrow.should eq 300
      found.wide.should eq 50_000_000
      found.blob.should eq Bytes[0, 1, 2, 255]
      found.doc.not_nil!["a"][1].as_i.should eq 2
      found.doc.not_nil!["b"].as_s.should eq "x"
      found.code.should eq "abc"
      found.amount.should eq BigDecimal.new("1234567.891")
      found.seen_at.not_nil!.to_utc.to_unix_ms.should eq stamp.to_unix_ms
      found.notes.should eq "n"
    end

    it "stores nulls" do
      found = W6bCatalogRow.find!(W6bCatalogRow.create!.id)
      found.tiny.should be_nil
      found.blob.should be_nil
      found.doc.should be_nil
      found.amount.should be_nil
    end
  end

  describe "PostgreSQL extension types as verbatim column types" do
    it "emits hstore, citext, ltree, inet and money exactly as named" do
      TestConnection.ensure_registered
      sql = W6bNativeRow.migrator.create_sql
      quote = CURRENT_ADAPTER == "mysql" ? "`" : "\""
      {"email" => "citext", "attrs" => "hstore", "path" => "ltree", "address" => "inet", "price" => "money"}.each do |name, type|
        sql.should contain "#{quote}#{name}#{quote} #{type}"
      end
    end
  end
end
