require "../../support/schema_fixture"

private def counting_adapter : M01CountingAdapter
  M01CountingAdapter.new(name: "m01_counting", url: ADAPTER_URL)
end

describe "Grant::Schema cache" do
  before_all { SchemaFixture.create! }
  after_all { SchemaFixture.drop! }

  describe "batching" do
    it "loads each kind of catalog data with one query for every table" do
      adapter = counting_adapter
      schema = adapter.schema

      schema.columns(:m01_authors)
      schema.columns(:m01_posts)
      schema.columns(:m01_memberships)
      schema.indexes(:m01_authors)
      schema.indexes(:m01_posts)
      schema.foreign_keys(:m01_posts)
      schema.foreign_keys(:m01_memberships)
      schema.table_exists?(:m01_posts)

      adapter.calls.sort.should eq ["columns:", "foreign_keys:", "indexes:", "tables"]
    end

    it "does not touch the catalog again on repeated reads" do
      adapter = counting_adapter
      schema = adapter.schema
      schema.columns(:m01_posts)
      schema.indexes(:m01_posts)
      schema.foreign_keys(:m01_posts)
      before = adapter.calls.size

      5.times do
        schema.columns(:m01_posts)
        schema.indexes(:m01_posts)
        schema.foreign_keys(:m01_posts)
        schema.tables
        schema.primary_key(:m01_posts)
      end

      adapter.calls.size.should eq before
    end
  end

  describe "#reset!" do
    it "makes the next read query everything again" do
      adapter = counting_adapter
      schema = adapter.schema
      schema.columns(:m01_authors)
      adapter.calls.clear

      schema.reset!
      schema.columns(:m01_authors)

      adapter.calls.should contain("columns:")
    end

    it "re-reads only the reset table" do
      adapter = counting_adapter
      schema = adapter.schema
      schema.columns(:m01_authors)
      schema.columns(:m01_posts)
      adapter.calls.clear

      schema.reset!(:m01_posts)
      schema.columns(:m01_authors)
      adapter.calls.should_not contain("columns:m01_authors")
      schema.columns(:m01_posts).map(&.name).should eq ["id", "author_id", "title", "score"]

      adapter.calls.select(&.starts_with?("columns")).should eq ["columns:m01_posts"]
    end
  end

  describe "DDL" do
    it "resets the table when Grant::Migrator creates or drops it" do
      schema = SchemaFixture.adapter.schema
      M01Note.migrator.drop
      schema.table_exists?(:m01_notes).should be_false
      schema.column_exists?(:m01_notes, :title).should be_false

      M01Note.migrator.create
      schema.table_exists?(:m01_notes).should be_true
      schema.columns(:m01_notes).map(&.name).should eq ["id", "title"]
      M01Note.table_exists?.should be_true

      M01Note.migrator.drop
      schema.table_exists?(:m01_notes).should be_false
      M01Note.table_exists?.should be_false
    end

    it "sees raw DDL only after reset!" do
      schema = SchemaFixture.adapter.schema
      schema.column_exists?(:m01_authors, :nickname).should be_false
      begin
        SchemaFixture.exec "ALTER TABLE m01_authors ADD COLUMN nickname VARCHAR(30)"
        schema.column_exists?(:m01_authors, :nickname).should be_false
        schema.reset!(:m01_authors)
        schema.column_exists?(:m01_authors, :nickname).should be_true
      ensure
        SchemaFixture.create!
      end
    end
  end

  describe "#dump and #load" do
    it "round trips the whole catalog through a file without queries" do
      path = File.tempname("m01_schema_cache", ".json")
      begin
        source = counting_adapter.schema
        source.dump(path)
        File.exists?(path).should be_true

        target_adapter = counting_adapter
        target = target_adapter.schema
        target.loaded?.should be_false
        target.load(path)

        target.loaded?.should be_true
        target.tables.should eq source.tables
        target.columns(:m01_posts).should eq source.columns(:m01_posts)
        target.indexes(:m01_posts).should eq source.indexes(:m01_posts)
        target.foreign_keys(:m01_memberships).should eq source.foreign_keys(:m01_memberships)
        target.primary_key(:m01_memberships).should eq ["author_id", "group_id"]
        target_adapter.calls.should be_empty
      ensure
        File.delete?(path)
      end
    end

    it "refuses a file from another adapter, another version, or garbage" do
      path = File.tempname("m01_schema_cache", ".json")
      begin
        schema = counting_adapter.schema
        schema.dump(path)
        original = File.read(path)

        File.write(path, original.sub(/"adapter":\s*"[^"]+"/, %("adapter": "Other")))
        expect_raises(Grant::Schema::CacheFileError, /Other/) { schema.load(path) }

        File.write(path, original.sub(/"version":\s*\d+/, %("version": 99)))
        expect_raises(Grant::Schema::CacheFileError, /version 99/) { schema.load(path) }

        File.write(path, "not json")
        expect_raises(Grant::Schema::CacheFileError) { schema.load(path) }

        expect_raises(Grant::Schema::CacheFileError) { schema.load("/nonexistent/m01.json") }
        schema.load?("/nonexistent/m01.json").should be_false
      ensure
        File.delete?(path)
      end
    end
  end
end
