require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class ScopedTenantRecord < Grant::Base
    connection {{ adapter_literal }}
    table scoped_tenant_records

    column id : Int64, primary: true
    column tenant_id : Int64?
    column record_id : Int64?
    column title : String
    column category : String
    column score : Int64 = 0_i64
    timestamps

    has_many :children, class_name: ScopedTenantChild, foreign_key: :record_id
    multitenant :tenant_id
  end

  class ScopedTenantChild < Grant::Base
    connection {{ adapter_literal }}
    table scoped_tenant_children

    column id : Int64, primary: true
    column tenant_id : Int64?
    column record_id : Int64
    column value : String

    multitenant :tenant_id
  end
{% end %}

describe "Grant multitenant default scope" do
  before_all do
    ScopedTenantChild.migrator.drop_and_create
    ScopedTenantRecord.migrator.drop_and_create
  end

  before_each do
    Grant::Tenant.clear
    ScopedTenantChild.unscoped.delete_all
    ScopedTenantRecord.unscoped.delete_all

    Grant::Tenant.with(1_i64) do
      first = ScopedTenantRecord.create!(title: "tenant one", category: "alpha", score: 10_i64)
      ScopedTenantRecord.create!(title: "tenant one other", category: "alpha", score: 20_i64)
      ScopedTenantChild.create!(record_id: first.id.not_nil!, value: "tenant one child")
    end

    Grant::Tenant.with(2_i64) do
      second = ScopedTenantRecord.create!(title: "tenant two", category: "beta", score: 100_i64)
      ScopedTenantChild.create!(record_id: second.id.not_nil!, value: "tenant two child")
    end
  end

  after_each do
    Grant::Tenant.clear
  end

  it "routes every read helper and query modifier through the tenant relation" do
    tenant_two_id = ScopedTenantRecord.unscoped.where(title: "tenant two").first!.id.not_nil!

    Grant::Tenant.with(1_i64) do
      ScopedTenantRecord.all.map(&.title).sort!.should eq(["tenant one", "tenant one other"])
      ScopedTenantRecord.select(:title).select.map(&.title).sort!.should eq(["tenant one", "tenant one other"])
      ScopedTenantRecord.where(title: "tenant two").select.should be_empty
      ScopedTenantRecord.where.not(:tenant_id, 1_i64).select.should be_empty
      ScopedTenantRecord.where(title: "missing").or(title: "tenant two").select.should be_empty
      ScopedTenantRecord.order(id: :desc).reorder(id: :asc).limit(1).offset(1).select.map(&.title).should eq(["tenant one other"])
      ScopedTenantRecord.distinct.select(:category).select.map(&.category).should eq(["alpha"])
      ScopedTenantRecord.group_by(:category).having("COUNT(*) > ?", 0_i64).select(:category).select.map(&.category).should eq(["alpha"])

      join_titles = ScopedTenantRecord
        .joins("scoped_tenant_children", on: "scoped_tenant_children.record_id = scoped_tenant_records.id")
        .select
        .map(&.title)
      join_titles.should eq(["tenant one"])
      ScopedTenantRecord.includes(:children).select.map(&.title).sort!.should eq(["tenant one", "tenant one other"])
      ScopedTenantRecord.preload(:children).select.map(&.title).sort!.should eq(["tenant one", "tenant one other"])
      ScopedTenantRecord.eager_load(:children).select.map(&.title).sort!.should eq(["tenant one", "tenant one other"])

      tenant_count = ScopedTenantRecord.count
      tenant_count.should be_a(Int64)
      tenant_count.should eq(2)
      ScopedTenantRecord.async_count.wait.should eq(2_i64)
      ScopedTenantRecord.async_all.wait.map(&.title).sort!.should eq(["tenant one", "tenant one other"])
      ScopedTenantRecord.sum(:score).should eq(30.0)
      ScopedTenantRecord.average(:score).should eq(15.0)
      ScopedTenantRecord.minimum(:score).should eq(10_i64)
      ScopedTenantRecord.maximum(:score).should eq(20_i64)
      ScopedTenantRecord.pluck(:title).map(&.as(String)).sort!.should eq(["tenant one", "tenant one other"])
      ScopedTenantRecord.ids.size.should eq(2)
      ScopedTenantRecord.pick(:title).should eq("tenant one")

      ScopedTenantRecord.exists?(tenant_two_id).should be_false
      ScopedTenantRecord.exists?(id: tenant_two_id).should be_false
      ScopedTenantRecord.where(id: tenant_two_id).exists?.should be_false
      ScopedTenantRecord.find(tenant_two_id).should be_nil
      expect_raises(Grant::Querying::NotFound) { ScopedTenantRecord.find!(tenant_two_id) }
      ScopedTenantRecord.find_by(title: "tenant two").should be_nil
      expect_raises(Grant::Querying::NotFound) { ScopedTenantRecord.find_by!(title: "tenant two") }
      ScopedTenantRecord.find_sole_by(title: "tenant one").tenant_id.should eq(1_i64)
      ScopedTenantRecord.first.not_nil!.title.should eq("tenant one")
      ScopedTenantRecord.first!.title.should eq("tenant one")
      ScopedTenantRecord.last.try(&.title).should eq("tenant one other")
      ScopedTenantRecord.last!.title.should eq("tenant one other")
      ScopedTenantRecord.take.try(&.title).should eq("tenant one")
      ScopedTenantRecord.take(2).size.should eq(2)

      each_titles = [] of String
      ScopedTenantRecord.find_each(batch_size: 1) { |record| each_titles << record.title }
      each_titles.sort.should eq(["tenant one", "tenant one other"])

      batch_sizes = [] of Int32
      ScopedTenantRecord.find_in_batches(batch_size: 1) { |batch| batch_sizes << batch.size }
      batch_sizes.should eq([1, 1])

      streamed_titles = [] of String
      ScopedTenantRecord.each_streamed { |record| streamed_titles << record.title }
      streamed_titles.size.should eq(2)
      streamed_titles.should_not contain("tenant two")
    end
  end

  it "raises without a tenant for reads and writes, while unscoped remains available" do
    Grant::Tenant.clear

    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.all }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.where(title: "tenant one") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.or(title: "tenant one") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.order(id: :asc) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.reorder(id: :asc) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.reverse_order }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.rewhere(title: "tenant one") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.reselect(:title) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.regroup(:category) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.limit(1) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.offset(1) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.lock }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.none }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.joins(:children) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.left_joins(:children) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.distinct }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.group_by(:category) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.having("COUNT(*) > ?", 1_i64) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.includes(:children) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.preload(:children) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.eager_load(:children) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.in_chunks(of: 1) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.use_index("idx_tenant_records") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.force_index("idx_tenant_records") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.ignore_index("idx_tenant_records") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.where.not(:title, "tenant one") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.select(:title) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.pluck(:title) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.pick(:title) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.ids }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.count }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.sum(:score) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.avg(:score) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.average(:score) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.min(:score) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.max(:score) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.async_count }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.async_pluck(:title) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.load_async }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.raw_all }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.all("WHERE title IN (?, ?)", ["tenant one", "tenant two"] of Grant::Columns::Type).to_a }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.exists?(1_i64) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.exists?(nil) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.exists?(title: "tenant one") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.minimum(:score) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.first }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.first! }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.last }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.last! }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.take }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.take(2) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.find(1_i64) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.find!(1_i64) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.find_by(title: "tenant one") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.find_by!(title: "tenant one") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.find_sole_by(title: "tenant one") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.sole }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.find_each { |_record| } }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.find_in_batches { |_batch| } }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.in_batches(of: 1) { |_batch| } }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.each_streamed { |_record| } }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.annotate("tenant required") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.explain }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.unscope(:where) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.update_counters(1_i64, {} of Symbol => Int32) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.update_all(title: "blocked") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.update_all("title = 'blocked'") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.delete }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.delete_all }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.destroy_all }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.upsert_all([] of Hash(String | Symbol, Grant::Columns::Type)) }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.touch_all }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.delete_by(title: "tenant one") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.destroy_by(title: "tenant one") }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.clear }
    expect_raises(Grant::NoTenantError) { ScopedTenantRecord.insert_all([] of Hash(String | Symbol, Grant::Columns::Type)) }

    ScopedTenantRecord.unscoped.count.should eq(3)
    ScopedTenantRecord.unscoped { ScopedTenantRecord.count }.should eq(3)
    ScopedTenantRecord.unscoped.where(title: "tenant two").select.size.should eq(1)
  end

  it "assigns tenants on new records and rejects explicit cross-tenant values" do
    Grant::Tenant.with(1_i64) do
      built = ScopedTenantRecord.new(title: "built", category: "alpha")
      built.tenant_id.should eq(1_i64)

      explicit = ScopedTenantRecord.new(tenant_id: 1_i64, title: "explicit", category: "alpha")
      explicit.tenant_id.should eq(1_i64)
      explicit.save.should be_true

      created = ScopedTenantRecord.create!(title: "auto-created", category: "alpha")
      created.tenant_id.should eq(1_i64)

      wrong = ScopedTenantRecord.new(tenant_id: 2_i64, title: "wrong", category: "beta")
      expect_raises(Grant::TenantMismatchError) { wrong.save }
      expect_raises(Grant::TenantMismatchError) do
        ScopedTenantRecord.create!(tenant_id: 2_i64, title: "wrong create", category: "beta")
      end

      cross_tenant = ScopedTenantRecord.unscoped do |_query|
        ScopedTenantRecord.create!(tenant_id: 2_i64, title: "allowed cross tenant", category: "beta")
      end
      cross_tenant.tenant_id.should eq(2_i64)
    end

    record_without_context = ScopedTenantRecord.new(title: "no tenant", category: "none")
    expect_raises(Grant::NoTenantError) { record_without_context.save }
  end

  it "tenant-guards instance save, update, update_columns, destroy, and reload" do
    tenant_one_id = ScopedTenantRecord.unscoped.where(title: "tenant one").first!.id.not_nil!
    tenant_two_id = ScopedTenantRecord.unscoped.where(title: "tenant two").first!.id.not_nil!

    Grant::Tenant.with(1_i64) do
      from_other_tenant = ScopedTenantRecord.unscoped.where(id: tenant_two_id).first!
      from_other_tenant.title = "changed across tenant"
      expect_raises(Grant::TenantMismatchError) { from_other_tenant.save }
      expect_raises(Grant::TenantMismatchError) { from_other_tenant.update(title: "changed by update") }
      expect_raises(Grant::TenantMismatchError) { from_other_tenant.update_columns(title: "changed directly") }
      expect_raises(Grant::TenantMismatchError) { from_other_tenant.destroy }
      expect_raises(Grant::Querying::NotFound) { from_other_tenant.reload }

      from_other_tenant.tenant_id = 2_i64
      ScopedTenantRecord.unscoped { from_other_tenant.update(title: "updated unscoped") }.should be_true
    end

    ScopedTenantRecord.unscoped.where(id: tenant_two_id).first!.title.should eq("updated unscoped")

    tenant_one_record = Grant::Tenant.with(1_i64) { ScopedTenantRecord.find!(tenant_one_id) }
    Grant::Tenant.with(2_i64) do
      expect_raises(Grant::TenantMismatchError) { tenant_one_record.update(title: "wrong context") }
      expect_raises(Grant::TenantMismatchError) { tenant_one_record.destroy }
    end
  end

  it "scopes bulk writes and applies the tenant to bulk-created rows" do
    tenant_two_id = ScopedTenantRecord.unscoped.where(title: "tenant two").first!.id.not_nil!
    attributes = [] of Hash(String | Symbol, Grant::Columns::Type)
    attributes << {"title" => "inserted", "category" => "alpha", "score" => 5_i64} of String | Symbol => Grant::Columns::Type
    upsert_attributes = [] of Hash(String | Symbol, Grant::Columns::Type)
    upsert_attributes << {"title" => "upserted", "category" => "alpha", "score" => 6_i64} of String | Symbol => Grant::Columns::Type

    Grant::Tenant.with(1_i64) do
      ScopedTenantRecord.insert_all(attributes)
      ScopedTenantRecord.upsert_all(upsert_attributes)
      ScopedTenantRecord.where(title: "tenant two").update_all(title: "not changed").should eq(0)
      ScopedTenantRecord.delete_by(title: "tenant two").should eq(0)
      ScopedTenantRecord.destroy_by(title: "tenant two").should eq(0)
      ScopedTenantRecord.where(title: "tenant two").delete_all.should eq(0)
      ScopedTenantRecord.where(title: "tenant two").destroy_all.should eq(0)
      ScopedTenantRecord.update_counters(tenant_two_id, {:score => 1}).should eq(0)
      ScopedTenantRecord.touch_all(time: Time.utc(2021, 1, 1)).should eq(4)
    end

    ScopedTenantRecord.unscoped.where(title: "inserted").first!.tenant_id.should eq(1_i64)
    ScopedTenantRecord.unscoped.where(title: "upserted").first!.tenant_id.should eq(1_i64)
    ScopedTenantRecord.unscoped.where(id: tenant_two_id).first!.title.should eq("tenant two")

    wrong_attributes = [] of Hash(String | Symbol, Grant::Columns::Type)
    wrong_attributes << {"title" => "wrong bulk", "category" => "beta", "tenant_id" => 2_i64} of String | Symbol => Grant::Columns::Type
    Grant::Tenant.with(1_i64) do
      expect_raises(Grant::TenantMismatchError) { ScopedTenantRecord.insert_all(wrong_attributes) }
    end

    imported = ScopedTenantRecord.new(title: "imported", category: "alpha")
    Grant::Tenant.with(1_i64) { ScopedTenantRecord.import([imported]) }
    ScopedTenantRecord.unscoped.where(title: "imported").first!.tenant_id.should eq(1_i64)

    Grant::Tenant.with(1_i64) do
      ScopedTenantRecord.update_all(title: "renamed tenant one").should eq(5)
      ScopedTenantRecord.destroy_all.should eq(5)
    end
    ScopedTenantRecord.unscoped.count.should eq(1)
  end

  it "does not let an upsert overwrite another tenant's row on a key collision" do
    tenant_two_id = ScopedTenantRecord.unscoped.where(title: "tenant two").first!.id.not_nil!
    rows = [] of Hash(String | Symbol, Grant::Columns::Type)
    rows << {"id" => tenant_two_id, "title" => "stolen", "category" => "alpha", "score" => 1_i64} of String | Symbol => Grant::Columns::Type

    Grant::Tenant.with(1_i64) do
      ScopedTenantRecord.upsert_all(rows, returning: [] of Symbol)
      ScopedTenantRecord.upsert_all(rows, returning: [] of Symbol, update_only: [:title])
    end

    untouched = ScopedTenantRecord.unscoped.where(id: tenant_two_id).first!
    untouched.title.should eq("tenant two")
    untouched.tenant_id.should eq(2_i64)
    untouched.score.should eq(100_i64)
  end

  it "lets an unscoped upsert update any tenant's row deliberately" do
    tenant_two_id = ScopedTenantRecord.unscoped.where(title: "tenant two").first!.id.not_nil!
    rows = [] of Hash(String | Symbol, Grant::Columns::Type)
    rows << {"id" => tenant_two_id, "tenant_id" => 2_i64, "title" => "admin rename", "category" => "beta", "score" => 100_i64} of String | Symbol => Grant::Columns::Type

    Grant::Tenant.with(1_i64) do
      ScopedTenantRecord.unscoped { ScopedTenantRecord.upsert_all(rows, returning: [] of Symbol) }
    end

    ScopedTenantRecord.unscoped.where(id: tenant_two_id).first!.title.should eq("admin rename")
  end
end
