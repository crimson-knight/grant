require "../../spec_helper"

class PgArrayTypeDoc < Grant::Base
  connection {{ env("CURRENT_ADAPTER") || "sqlite" }}
  table pg_array_type_docs

  column id : Int64, primary: true
  column title : String?
  column tags : Array(String)?
  column scores : Array(Int32)?
  column flags : Array(Bool)?
  column refs : Array(UUID)?
end

describe "PostgreSQL array columns" do
  if CURRENT_ADAPTER == "pg"
    before_each do
      PgArrayTypeDoc.migrator.drop_and_create
    end

    it "creates native array columns" do
      types = {} of String => String
      PgArrayTypeDoc.adapter.open do |db|
        db.query("SELECT column_name, udt_name FROM information_schema.columns WHERE table_name = 'pg_array_type_docs'") do |rs|
          rs.each { types[rs.read(String)] = rs.read(String) }
        end
      end
      types["tags"].should eq "_text"
      types["scores"].should eq "_int4"
      types["flags"].should eq "_bool"
      types["refs"].should eq "_uuid"
    end

    it "round trips String, Int32, Bool and UUID arrays, including empty and NULL" do
      ids = [UUID.random, UUID.random]
      doc = PgArrayTypeDoc.create!(title: "a", tags: ["crystal", "orm"], scores: [1, 2, 3], flags: [true, false], refs: ids)
      reloaded = PgArrayTypeDoc.find!(doc.id)
      reloaded.tags.should eq ["crystal", "orm"]
      reloaded.scores.should eq [1, 2, 3]
      reloaded.flags.should eq [true, false]
      reloaded.refs.should eq ids

      empty = PgArrayTypeDoc.create!(title: "e", tags: [] of String)
      PgArrayTypeDoc.find!(empty.id).tags.should eq [] of String
      PgArrayTypeDoc.find!(empty.id).scores.should be_nil

      reloaded.tags = ["changed"]
      reloaded.save!
      PgArrayTypeDoc.find!(doc.id).tags.should eq ["changed"]
    end

    describe "operators" do
      before_each do
        PgArrayTypeDoc.create!(title: "one", tags: ["crystal", "orm"], scores: [1, 2])
        PgArrayTypeDoc.create!(title: "two", tags: ["ruby", "rails"], scores: [3])
        PgArrayTypeDoc.create!(title: "three", tags: ["crystal", "ruby"], scores: [2, 3])
        PgArrayTypeDoc.create!(title: "four")
      end

      it "array_contains matches rows holding every element" do
        PgArrayTypeDoc.where.array_contains(:tags, ["crystal"]).order(:title).select.map(&.title).should eq ["one", "three"]
        PgArrayTypeDoc.where.array_contains(:tags, ["crystal", "ruby"]).select.map(&.title).should eq ["three"]
        PgArrayTypeDoc.where.array_contains(:scores, [2, 3]).select.map(&.title).should eq ["three"]
      end

      it "array_overlaps matches rows sharing any element" do
        PgArrayTypeDoc.where.array_overlaps(:tags, ["orm", "rails"]).order(:title).select.map(&.title).should eq ["one", "two"]
        PgArrayTypeDoc.where.array_overlaps(:tags, [] of String).select.should be_empty
      end

      it "any matches a single element" do
        PgArrayTypeDoc.where.any(:tags, "rails").select.map(&.title).should eq ["two"]
        PgArrayTypeDoc.where.any(:scores, 3).order(:title).select.map(&.title).should eq ["three", "two"]
      end

      it "array_contained_by matches rows whose array fits inside the list" do
        PgArrayTypeDoc.where.array_contained_by(:tags, ["ruby", "rails", "go"]).select.map(&.title).should eq ["two"]
      end

      it "binds one array parameter, not one placeholder per element" do
        many = (1..500).map(&.to_s)
        assembler = PgArrayTypeDoc.where.array_overlaps(:tags, many).assembler
        assembler.select.raw_sql.should contain("&& $1")
        assembler.select.raw_sql.should_not contain("$2")
        assembler.numbered_parameters.size.should eq 1
        PgArrayTypeDoc.where.array_overlaps(:tags, many).select.should be_empty
      end

      it "composes with other conditions and leaves the receiver untouched" do
        base = PgArrayTypeDoc.where.array_contains(:tags, ["ruby"])
        narrowed = base.where(title: "two")
        base.select.size.should eq 2
        narrowed.select.map(&.title).should eq ["two"]
      end
    end
  else
    it "raises a clear unsupported error for array columns on #{CURRENT_ADAPTER}" do
      expect_raises(Grant::Schema::UnsupportedOperation, /Array\(String\)/) do
        PgArrayTypeDoc.migrator.drop_and_create
      end
    end

    it "raises a clear unsupported error for array operators on #{CURRENT_ADAPTER}" do
      expect_raises(Grant::Schema::UnsupportedOperation, /PostgreSQL array/) do
        PgArrayTypeDoc.where.array_contains(:tags, ["a"])
      end
      expect_raises(Grant::Schema::UnsupportedOperation, /PostgreSQL array/) do
        PgArrayTypeDoc.where.array_overlaps(:tags, ["a"])
      end
      expect_raises(Grant::Schema::UnsupportedOperation, /PostgreSQL array/) do
        PgArrayTypeDoc.where.any(:tags, "a")
      end
    end
  end
end
