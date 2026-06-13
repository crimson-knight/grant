require "../../spec_helper"

# ---------------------------------------------------------------------------
# Models for the large-table toolkit specs
# ---------------------------------------------------------------------------

class HintModel < Grant::Base
  connection {{ env("CURRENT_ADAPTER").id }}
  table hint_models

  column id : Int64, primary: true
  column name : String?
  column score : Int32?
end

class ChunkModel < Grant::Base
  connection {{ env("CURRENT_ADAPTER").id }}
  table chunk_models

  column id : Int64, primary: true
  column name : String?
  column score : Int32?
end

class StreamModel < Grant::Base
  connection {{ env("CURRENT_ADAPTER").id }}
  table stream_models

  column id : Int64, primary: true
  column name : String?
end

class TenantTodo < Grant::Base
  connection {{ env("CURRENT_ADAPTER").id }}
  table tenant_todos

  column id : Int64, primary: true
  column tenant_id : Int64?
  column title : String?
  column done : Bool = false

  multitenant :tenant_id
end

private def reset_hint_index!
  # Build a real index used by the index-hint specs.
  HintModel.adapter.open do |db|
    begin
      db.exec "DROP INDEX IF EXISTS idx_hint_models_score"
    rescue
    end
    db.exec "CREATE INDEX idx_hint_models_score ON hint_models (score)"
  end
end

describe "Large-table / high-scale toolkit" do
  before_all do
    HintModel.migrator.drop_and_create
    ChunkModel.migrator.drop_and_create
    StreamModel.migrator.drop_and_create
    TenantTodo.migrator.drop_and_create
    reset_hint_index!
  end

  before_each do
    Grant.settings.index_hint_mode = :warn
    Grant.settings.in_clause_limit = 1000
    Grant::Tenant.clear
    HintModel.clear
    ChunkModel.clear
    StreamModel.clear
    # `clear` truncates directly via the adapter, bypassing the tenant scope.
    TenantTodo.clear
  end

  # -------------------------------------------------------------------------
  # 2.1 Index hints + safe fallback
  # -------------------------------------------------------------------------
  describe "index hints" do
    it "renders an adapter-supported hint into the SQL (SQLite INDEXED BY)" do
      sql = HintModel.where(score: 5).use_index("idx_hint_models_score").raw_sql
      {% if env("CURRENT_ADAPTER") == "sqlite" %}
        sql.should contain("INDEXED BY")
        sql.should contain("idx_hint_models_score")
      {% elsif env("CURRENT_ADAPTER") == "mysql" %}
        sql.should contain("USE INDEX")
      {% else %}
        # Postgres degrades: no hint in SQL
        sql.should_not contain("INDEX")
      {% end %}
    end

    it "preserves index hints across dup" do
      original = HintModel.where(score: 5).use_index("idx_hint_models_score")
      original.index_hints.size.should eq(1)
      original.dup.index_hints.size.should eq(1)
    end

    it ":warn mode returns identical results with and without a (valid) hint" do
      HintModel.create(id: 1_i64, name: "a", score: 5)
      HintModel.create(id: 2_i64, name: "b", score: 5)
      HintModel.create(id: 3_i64, name: "c", score: 9)

      plain = HintModel.where(score: 5).order(:id).select.map(&.id!)
      hinted = HintModel.where(score: 5).order(:id).use_index("idx_hint_models_score").select.map(&.id!)

      hinted.should eq(plain)
      hinted.should eq([1_i64, 2_i64])
    end

    it ":warn mode falls back and still returns rows for a MISSING index" do
      Grant.settings.index_hint_mode = :warn
      HintModel.create(id: 1_i64, name: "a", score: 5)
      HintModel.create(id: 2_i64, name: "b", score: 5)

      # Re-run-without-hint must yield the same results.
      results = HintModel.where(score: 5).order(:id).use_index("idx_does_not_exist").select.map(&.id!)
      results.should eq([1_i64, 2_i64])
    end

    it ":ignore mode silently drops an unsupported/missing hint and returns rows" do
      Grant.settings.index_hint_mode = :ignore
      HintModel.create(id: 1_i64, name: "a", score: 5)

      results = HintModel.where(score: 5).use_index("idx_does_not_exist").select.map(&.id!)
      results.should eq([1_i64])
    end

    {% if env("CURRENT_ADAPTER") == "sqlite" %}
      it ":strict mode raises for a missing index (SQLite)" do
        Grant.settings.index_hint_mode = :strict
        HintModel.create(id: 1_i64, name: "a", score: 5)

        expect_raises(Exception) do
          HintModel.where(score: 5).use_index("idx_does_not_exist").select
        end
      end

      it ":strict mode raises UnsupportedIndexHintError for an unsupported KIND (SQLite IGNORE)" do
        Grant.settings.index_hint_mode = :strict
        HintModel.create(id: 1_i64, name: "a", score: 5)

        expect_raises(Grant::UnsupportedIndexHintError) do
          HintModel.where(score: 5).ignore_index("idx_hint_models_score").select
        end
      end

      it ":warn mode degrades an unsupported KIND (SQLite IGNORE) and returns rows" do
        Grant.settings.index_hint_mode = :warn
        HintModel.create(id: 1_i64, name: "a", score: 5)

        results = HintModel.where(score: 5).ignore_index("idx_hint_models_score").select.map(&.id!)
        results.should eq([1_i64])
      end
    {% end %}

    {% if env("CURRENT_ADAPTER") == "pg" %}
      it "Postgres degrades all hints (no core hint syntax) and still returns rows" do
        Grant.settings.index_hint_mode = :warn
        HintModel.create(id: 1_i64, name: "a", score: 5)
        results = HintModel.where(score: 5).force_index("anything").select.map(&.id!)
        results.should eq([1_i64])
      end
    {% end %}
  end

  # -------------------------------------------------------------------------
  # 2.2 Large-IN-list chunking
  # -------------------------------------------------------------------------
  describe "IN-list chunking" do
    it "does not chunk when the array is within the limit" do
      Grant.settings.in_clause_limit = 1000
      ChunkModel.where(id: [1_i64, 2_i64, 3_i64]).should_chunk_in?.should be_false
    end

    it "chunks and returns the full de-duplicated record set across chunks" do
      (1..25).each { |i| ChunkModel.create(id: i.to_i64, name: "n#{i}", score: i) }

      ids = (1..25).map(&.to_i64).to_a
      results = ChunkModel.where(id: ids).in_chunks(of: 10).select
      results.map(&.id!).sort.should eq(ids)
      # de-dup: each pk appears once
      results.map(&.id!).uniq.size.should eq(results.size)
    end

    it "honors ORDER across chunk boundaries (merge-sort)" do
      (1..25).each { |i| ChunkModel.create(id: i.to_i64, name: "n#{i}", score: i) }

      ids = (1..25).map(&.to_i64).to_a
      ordered = ChunkModel.where(id: ids).in_chunks(of: 10).order(score: :desc).select.map(&.score!)
      ordered.should eq((1..25).to_a.reverse)
    end

    it "honors LIMIT across chunk boundaries" do
      (1..25).each { |i| ChunkModel.create(id: i.to_i64, name: "n#{i}", score: i) }

      ids = (1..25).map(&.to_i64).to_a
      # Global ascending order, limit 5 -> the five smallest scores.
      limited = ChunkModel.where(id: ids).in_chunks(of: 10).order(score: :asc).limit(5).select.map(&.score!)
      limited.should eq([1, 2, 3, 4, 5])
    end

    it "sums chunk counts for count" do
      (1..25).each { |i| ChunkModel.create(id: i.to_i64, name: "n#{i}", score: i) }
      ids = (1..25).map(&.to_i64).to_a
      ChunkModel.where(id: ids).in_chunks(of: 10).count.should eq(25_i64)
    end

    it "concatenates + de-duplicates ids across chunks" do
      (1..25).each { |i| ChunkModel.create(id: i.to_i64, name: "n#{i}", score: i) }
      ids = (1..25).map(&.to_i64).to_a
      got = ChunkModel.where(id: ids).in_chunks(of: 10).ids.map(&.as(Int64)).sort
      got.should eq(ids)
    end

    it "chunks pluck across chunks" do
      (1..25).each { |i| ChunkModel.create(id: i.to_i64, name: "n#{i}", score: i) }
      ids = (1..25).map(&.to_i64).to_a
      names = ChunkModel.where(id: ids).in_chunks(of: 10).pluck(:name).map(&.first.to_s).sort
      names.size.should eq(25)
    end

    it "chunks update_all and returns the summed rows_affected" do
      (1..25).each { |i| ChunkModel.create(id: i.to_i64, name: "n#{i}", score: i) }
      ids = (1..25).map(&.to_i64).to_a
      affected = ChunkModel.where(id: ids).in_chunks(of: 10).update_all(score: 0)
      affected.should eq(25_i64)
      ChunkModel.where(score: 0).count.should eq(25_i64)
    end

    it "chunks delete_all and returns the summed rows_affected" do
      (1..25).each { |i| ChunkModel.create(id: i.to_i64, name: "n#{i}", score: i) }
      ids = (1..25).map(&.to_i64).to_a
      affected = ChunkModel.where(id: ids).in_chunks(of: 10).delete_all
      affected.should eq(25_i64)
      ChunkModel.count.should eq(0_i64)
    end

    it "uses the global in_clause_limit when no per-query override is set" do
      Grant.settings.in_clause_limit = 5
      (1..12).each { |i| ChunkModel.create(id: i.to_i64, name: "n#{i}", score: i) }
      ids = (1..12).map(&.to_i64).to_a
      q = ChunkModel.where(id: ids)
      q.should_chunk_in?.should be_true
      q.select.map(&.id!).sort.should eq(ids)
    end

    it "preserves the per-query in_chunks override across dup" do
      ids = (1..30).map(&.to_i64).to_a
      q = ChunkModel.where(id: ids).in_chunks(of: 10)
      q.should_chunk_in?.should be_true
      q.dup.should_chunk_in?.should be_true # override survives dup
    end
  end

  # -------------------------------------------------------------------------
  # 2.3 Result streaming
  # -------------------------------------------------------------------------
  describe "each_streamed" do
    it "yields all matching rows one at a time" do
      (1..50).each { |i| StreamModel.create(id: i.to_i64, name: "s#{i}") }

      seen = [] of Int64
      StreamModel.where.gt(:id, 0).order(:id).each_streamed do |record|
        seen << record.id!
      end

      seen.should eq((1..50).map(&.to_i64).to_a)
    end

    it "hydrates real Model instances" do
      StreamModel.create(id: 1_i64, name: "only")
      names = [] of String?
      StreamModel.each_streamed { |r| names << r.name }
      names.should eq(["only"])
    end

    it "is a no-op for a none relation" do
      count = 0
      StreamModel.none.each_streamed { |_r| count += 1 }
      count.should eq(0)
    end
  end

  # -------------------------------------------------------------------------
  # 2.4 First-class tenant scoping
  # -------------------------------------------------------------------------
  describe "multitenant scoping" do
    it "auto-filters queries by the current tenant" do
      Grant::Tenant.with(1_i64) do
        TenantTodo.create(id: 1_i64, tenant_id: 1_i64, title: "t1a")
        TenantTodo.create(id: 2_i64, tenant_id: 1_i64, title: "t1b")
      end
      Grant::Tenant.with(2_i64) do
        TenantTodo.create(id: 3_i64, tenant_id: 2_i64, title: "t2a")
      end

      Grant::Tenant.with(1_i64) do
        TenantTodo.all.map(&.id!).sort.should eq([1_i64, 2_i64])
      end
      Grant::Tenant.with(2_i64) do
        TenantTodo.all.map(&.id!).should eq([3_i64])
      end
    end

    it "raises NoTenantError when querying without a tenant set" do
      expect_raises(Grant::NoTenantError) do
        TenantTodo.all
      end
    end

    it "current!/current/with are fiber-local and restore correctly" do
      Grant::Tenant.current.should be_nil
      Grant::Tenant.with(7_i64) do
        Grant::Tenant.current.should eq(7_i64)
        Grant::Tenant.with(8_i64) do
          Grant::Tenant.current.should eq(8_i64)
        end
        Grant::Tenant.current.should eq(7_i64)
      end
      Grant::Tenant.current.should be_nil
    end

    it "isolates tenant context across fibers" do
      results = {} of Symbol => Grant::Columns::Type
      ch = Channel(Nil).new

      spawn do
        Grant::Tenant.with(100_i64) do
          Fiber.yield
          results[:a] = Grant::Tenant.current
        end
        ch.send(nil)
      end

      spawn do
        Grant::Tenant.with(200_i64) do
          Fiber.yield
          results[:b] = Grant::Tenant.current
        end
        ch.send(nil)
      end

      2.times { ch.receive }
      results[:a].should eq(100_i64)
      results[:b].should eq(200_i64)
    end

    it "unscoped { } bypasses the tenant scope (cross-tenant access)" do
      Grant::Tenant.with(1_i64) { TenantTodo.create(id: 1_i64, tenant_id: 1_i64, title: "t1") }
      Grant::Tenant.with(2_i64) { TenantTodo.create(id: 2_i64, tenant_id: 2_i64, title: "t2") }

      # No tenant set, but unscoped sees everything without raising.
      all_ids = TenantTodo.unscoped.select.map(&.id!).sort
      all_ids.should eq([1_i64, 2_i64])
    end

    it "exposes the multitenant column for introspection" do
      TenantTodo.multitenant_column.should eq("tenant_id")
    end
  end
end
