require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6bArrayDoc < Grant::Base
    connection {{ adapter_literal }}
    table w6b_array_docs

    column id : Int64, primary: true
    column title : String?
    column tags : Array(String)?
    column scores : Array(Int64)?
    column seen_at : Array(Time)?

    gin_index :tags
  end
{% end %}

describe "PostgreSQL array helpers" do
  if CURRENT_ADAPTER == "pg"
    before_each do
      W6bArrayDoc.migrator.drop_and_create
    end

    describe "Array(Time) columns" do
      it "creates a timestamp[] column and round trips instants, empty and NULL" do
        types = {} of String => String
        W6bArrayDoc.adapter.open do |db|
          db.query("SELECT column_name, udt_name FROM information_schema.columns WHERE table_name = 'w6b_array_docs'") do |rs|
            rs.each { types[rs.read(String)] = rs.read(String) }
          end
        end
        types["seen_at"].should eq "_timestamp"

        first = Time.utc(2026, 9, 1, 8, 30, 15)
        second = Time.utc(2026, 9, 2, 0, 0, 0)
        doc = W6bArrayDoc.create!(title: "t", seen_at: [first, second])
        W6bArrayDoc.find!(doc.id).seen_at.should eq [first, second]

        W6bArrayDoc.find!(W6bArrayDoc.create!(title: "e", seen_at: [] of Time).id).seen_at.should eq [] of Time
        W6bArrayDoc.find!(W6bArrayDoc.create!(title: "n").id).seen_at.should be_nil
      end

      it "tracks changes and supports the array predicates" do
        first = Time.utc(2026, 9, 1)
        second = Time.utc(2026, 9, 2)
        doc = W6bArrayDoc.create!(title: "t", seen_at: [first])
        doc.seen_at = [first, second]
        doc.seen_at_changed?.should be_true
        doc.save!
        W6bArrayDoc.find!(doc.id).seen_at.should eq [first, second]

        W6bArrayDoc.where.array_contains(:seen_at, [second]).select.map(&.title).should eq ["t"]
        W6bArrayDoc.where.array_contains(:seen_at, [Time.utc(2030, 1, 1)]).select.should be_empty
        W6bArrayDoc.where.any(:seen_at, first).select.map(&.title).should eq ["t"]
      end
    end

    describe "array_append_all and array_remove_all" do
      before_each do
        W6bArrayDoc.create!(title: "one", tags: ["crystal"], scores: [1_i64])
        W6bArrayDoc.create!(title: "two", tags: ["ruby", "crystal", "crystal"], scores: [2_i64, 3_i64])
        W6bArrayDoc.create!(title: "three", tags: [] of String)
      end

      it "appends one element to every matching row in a single UPDATE" do
        W6bArrayDoc.where(title: "one").array_append_all(:tags, "orm").should eq 1
        W6bArrayDoc.find_by!(title: "one").tags.should eq ["crystal", "orm"]
        W6bArrayDoc.find_by!(title: "two").tags.should eq ["ruby", "crystal", "crystal"]

        W6bArrayDoc.all.array_append_all(:scores, 9_i64).should eq 3
        W6bArrayDoc.find_by!(title: "two").scores.should eq [2_i64, 3_i64, 9_i64]
        W6bArrayDoc.find_by!(title: "three").scores.should eq [9_i64]
      end

      it "removes every occurrence of an element" do
        W6bArrayDoc.where.array_contains(:tags, ["crystal"]).array_remove_all(:tags, "crystal").should eq 2
        W6bArrayDoc.find_by!(title: "one").tags.should eq [] of String
        W6bArrayDoc.find_by!(title: "two").tags.should eq ["ruby"]
        W6bArrayDoc.find_by!(title: "three").tags.should eq [] of String
      end

      it "binds the value and keeps the relation's conditions" do
        sql = StatementRecorder.statements { W6bArrayDoc.where(title: "two").array_append_all(:tags, "x'; DROP TABLE w6b_array_docs; --") }
        sql.any?(&.includes?("array_append")).should be_true
        sql.none?(&.includes?("DROP TABLE")).should be_true
        W6bArrayDoc.count.should eq 3
        W6bArrayDoc.find_by!(title: "two").tags.not_nil!.last.should eq "x'; DROP TABLE w6b_array_docs; --"
        W6bArrayDoc.find_by!(title: "one").tags.should eq ["crystal"]
      end

      it "returns 0 for a none relation and rejects an invalid column name" do
        W6bArrayDoc.none.array_append_all(:tags, "x").should eq 0
        expect_raises(ArgumentError) { W6bArrayDoc.all.array_append_all("tags; DROP", "x") }
      end
    end

    describe "array_length" do
      before_each do
        W6bArrayDoc.create!(title: "none", tags: [] of String)
        W6bArrayDoc.create!(title: "two", tags: ["a", "b"])
        W6bArrayDoc.create!(title: "three", tags: ["a", "b", "c"])
        W6bArrayDoc.create!(title: "null")
      end

      it "compares the element count, counting an empty array as 0 and skipping NULL" do
        titles = ->(relation : Grant::Query::Builder(W6bArrayDoc)) { relation.order(:title).select.map(&.title) }
        titles.call(W6bArrayDoc.where.array_length(:tags, 0)).should eq ["none"]
        titles.call(W6bArrayDoc.where.array_length(:tags, 2)).should eq ["two"]
        titles.call(W6bArrayDoc.where.array_length(:tags, 2, :gte)).should eq ["three", "two"]
        titles.call(W6bArrayDoc.where.array_length(:tags, 3, :lt)).should eq ["none", "two"]
        titles.call(W6bArrayDoc.where.array_length(:tags, 0, :gt)).should eq ["three", "two"]
        titles.call(W6bArrayDoc.where.array_length(:tags, 2, :ne)).should eq ["none", "three"]
      end

      it "binds the length and rejects an unknown operator" do
        assembler = W6bArrayDoc.where.array_length(:tags, 2).assembler
        assembler.select.raw_sql.should contain("cardinality(")
        assembler.numbered_parameters.size.should eq 1
        expect_raises(ArgumentError, /operator/) { W6bArrayDoc.where.array_length(:tags, 2, :like) }
      end
    end

    describe "GIN index" do
      it "builds a GIN index from the model declaration and the statement helper" do
        indexes = {} of String => String
        W6bArrayDoc.adapter.open do |db|
          db.query("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'w6b_array_docs'") do |rs|
            rs.each { indexes[rs.read(String)] = rs.read(String) }
          end
        end
        indexes.values.any?(&.includes?("USING gin (tags)")).should be_true

        statements = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
        statements.add_gin_index_statements(:posts, :tags).should eq ["CREATE INDEX \"index_posts_on_tags\" ON \"posts\" USING gin (\"tags\")"]
        statements.add_gin_index_statements(:posts, :tags, name: "posts_tags_gin", if_not_exists: true)
          .should eq ["CREATE INDEX IF NOT EXISTS \"posts_tags_gin\" ON \"posts\" USING gin (\"tags\")"]
      end

      it "makes @> queries use the index" do
        200.times { |i| W6bArrayDoc.create!(title: "row#{i}", tags: ["t#{i}"]) }
        plan = [] of String
        W6bArrayDoc.adapter.open do |db|
          db.exec("SET enable_seqscan = off")
          db.query("EXPLAIN SELECT id FROM w6b_array_docs WHERE tags @> ARRAY['t5']::text[]") { |rs| rs.each { plan << rs.read(String) } }
          db.exec("RESET enable_seqscan")
        end
        plan.join("\n").should contain("Index")
      end
    end
  else
    it "raises a clear unsupported error for the array helpers on #{CURRENT_ADAPTER}" do
      expect_raises(Grant::Schema::UnsupportedOperation, /array/i) { W6bArrayDoc.where.array_length(:tags, 1) }
      expect_raises(Grant::Schema::UnsupportedOperation, /array/i) { W6bArrayDoc.all.array_append_all(:tags, "x") }
      expect_raises(Grant::Schema::UnsupportedOperation, /array/i) { W6bArrayDoc.all.array_remove_all(:tags, "x") }
    end

    it "raises a clear unsupported error for a GIN index on #{CURRENT_ADAPTER}" do
      statements = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite)
      expect_raises(Grant::Schema::UnsupportedOperation, /GIN/) { statements.add_gin_index_statements(:posts, :tags) }
      expect_raises(Grant::Schema::UnsupportedOperation, /GIN/) { Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).add_gin_index_statements(:posts, :tags) }
    end
  end
end
