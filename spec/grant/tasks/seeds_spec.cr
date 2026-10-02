require "../../spec_helper"

private def m04_seed_adapter : Grant::Adapter::Base
  Grant::ConnectionRegistry.get_adapter(CURRENT_ADAPTER)
end

private def m04_reset_seeds : Nil
  m04_seed_adapter.open(&.exec("DROP TABLE IF EXISTS grant_seeds"))
  m04_seed_adapter.open { |db| db.exec "DROP TABLE IF EXISTS m04_seed_items" }
  m04_seed_adapter.reset_schema_caches!
  Grant::Seeds.clear_definitions!
end

describe Grant::Seeds do
  before_each { m04_reset_seeds }
  after_all { m04_reset_seeds }

  describe ".load_once" do
    it "runs the block once and records the name" do
      count = 0
      Grant::Seeds.load_once("first", m04_seed_adapter) { count += 1 }.should be_true
      Grant::Seeds.load_once("first", m04_seed_adapter) { count += 1 }.should be_false
      Grant::Seeds.load_once("first", m04_seed_adapter) { count += 1 }.should be_false
      count.should eq 1
      Grant::Seeds.applied?("first", m04_seed_adapter).should be_true
      Grant::Seeds.applied(m04_seed_adapter).should eq ["first"]
    end

    it "keeps separate names independent" do
      ran = [] of String
      Grant::Seeds.load_once("a", m04_seed_adapter) { ran << "a" }
      Grant::Seeds.load_once("b", m04_seed_adapter) { ran << "b" }
      Grant::Seeds.load_once("a", m04_seed_adapter) { ran << "a again" }
      ran.should eq ["a", "b"]
      Grant::Seeds.applied(m04_seed_adapter).sort.should eq ["a", "b"]
    end

    it "commits the record and the block's writes together, so a failing block runs again" do
      adapter = m04_seed_adapter
      adapter.open { |db| db.exec "CREATE TABLE m04_seed_items (name VARCHAR(40))" }
      attempts = 0
      expect_raises(Exception, "boom") do
        Grant::Seeds.load_once("flaky", m04_seed_adapter) do
          adapter.open { |db| db.exec "INSERT INTO m04_seed_items (name) VALUES ('partial')" }
          attempts += 1
          raise "boom"
        end
      end
      Grant::Seeds.applied?("flaky", m04_seed_adapter).should be_false
      adapter.open { |db| db.scalar("SELECT COUNT(*) FROM m04_seed_items").as(Int).to_i64 }.should eq 0

      Grant::Seeds.load_once("flaky", m04_seed_adapter) do
        adapter.open { |db| db.exec "INSERT INTO m04_seed_items (name) VALUES ('whole')" }
        attempts += 1
      end.should be_true
      attempts.should eq 2
      adapter.open { |db| db.scalar("SELECT COUNT(*) FROM m04_seed_items").as(Int).to_i64 }.should eq 1
    end

    it "can be reset with forget" do
      count = 0
      Grant::Seeds.load_once("again", m04_seed_adapter) { count += 1 }
      Grant::Seeds.forget("again", m04_seed_adapter)
      Grant::Seeds.load_once("again", m04_seed_adapter) { count += 1 }
      count.should eq 2
    end

    it "reports whether any seed was applied without creating the table" do
      Grant::Seeds.any_applied?(m04_seed_adapter).should be_false
      m04_seed_adapter.reset_schema_caches!
      m04_seed_adapter.schema.table_exists?("grant_seeds").should be_false
      Grant::Seeds.load_once("x", m04_seed_adapter) { }
      Grant::Seeds.any_applied?(m04_seed_adapter).should be_true
    end
  end

  describe ".define and .run" do
    it "runs the blocks registered for the seeds path, each step idempotent with load_once" do
      log = [] of String
      Grant::Seeds.define("/project/db/seeds.cr") do
        Grant::Seeds.load_once("one", m04_seed_adapter) { log << "one" }
        log << "always"
      end
      Grant::Seeds.define("/project/db/other_seeds.cr") { log << "other file" }

      Grant::Seeds.defined?("db/seeds.cr").should be_true
      Grant::Seeds.run("db/seeds.cr").should eq 1
      Grant::Seeds.run("db/seeds.cr").should eq 1
      log.should eq ["one", "always", "always"]
    end

    it "raises SeedFileMissing for an unknown file and SeedsNotCompiled for an existing one" do
      expect_raises(Grant::Seeds::SeedFileMissing, /m04_no_seeds.cr/) { Grant::Seeds.run("db/m04_no_seeds.cr") }
      expect_raises(Grant::Seeds::SeedsNotCompiled) { Grant::Seeds.run(__FILE__) }
    end
  end
end
