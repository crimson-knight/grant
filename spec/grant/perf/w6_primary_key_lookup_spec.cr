require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6LookupNote < Grant::Base
    connection {{ adapter_literal }}
    table w6_lookup_notes

    column id : Int64, primary: true
    column body : String
    column visible : Bool = true

    default_scope { where(visible: true) }
  end

  class W6LookupPlain < Grant::Base
    connection {{ adapter_literal }}
    table w6_lookup_plains

    column id : Int64, primary: true
    column label : String
  end

  class W6LookupSlug < Grant::Base
    connection {{ adapter_literal }}
    table w6_lookup_slugs

    column slug : String, primary: true, auto: false
    column label : String
  end
{% end %}

W6LookupNote.migrator.drop_and_create
W6LookupPlain.migrator.drop_and_create
W6LookupSlug.migrator.drop_and_create

describe "Model.find with a kept statement" do
  before_each do
    W6LookupNote.unscoped(&.delete_all)
    W6LookupPlain.clear
    W6LookupSlug.clear
  end

  it "finds a record of a model with no scope, again and again" do
    plain = W6LookupPlain.create!(label: "p")

    3.times { W6LookupPlain.find(plain.id).not_nil!.label.should eq("p") }
    W6LookupPlain.find!(plain.id).label.should eq("p")
  end

  it "accepts Int32 and String keys for an integer column like the relation does" do
    plain = W6LookupPlain.create!(label: "k")

    W6LookupPlain.find(plain.id.not_nil!.to_i32).not_nil!.label.should eq("k")
    W6LookupPlain.find(plain.id.to_s).not_nil!.label.should eq("k")
  end

  it "finds a record by a String primary key" do
    W6LookupSlug.create!(slug: "alpha", label: "first")

    W6LookupSlug.find("alpha").not_nil!.label.should eq("first")
    W6LookupSlug.find("missing").should be_nil
  end

  it "keeps honoring a default scope" do
    shown = W6LookupNote.create!(body: "shown", visible: true)
    hidden = W6LookupNote.create!(body: "hidden", visible: false)

    W6LookupNote.find(shown.id).not_nil!.body.should eq("shown")
    W6LookupNote.find(hidden.id).should be_nil
    expect_raises(Grant::Querying::NotFound) { W6LookupNote.find!(hidden.id) }
  end

  it "skips the default scope inside unscoped" do
    hidden = W6LookupNote.create!(body: "hidden", visible: false)

    W6LookupNote.unscoped { W6LookupNote.find(hidden.id) }.not_nil!.body.should eq("hidden")
    W6LookupNote.find(hidden.id).should be_nil
  end

  it "keeps honoring a scoping block" do
    first = W6LookupPlain.create!(label: "keep")
    second = W6LookupPlain.create!(label: "other")

    W6LookupPlain.scoping(W6LookupPlain.where(label: "keep")) do
      W6LookupPlain.find(first.id).should_not be_nil
      W6LookupPlain.find(second.id).should be_nil
    end
    W6LookupPlain.find(second.id).should_not be_nil
  end

  it "is served from the query cache like any relation read" do
    plain = W6LookupPlain.create!(label: "cached")

    Grant::QueryCache.cache do
      W6LookupPlain.find(plain.id).not_nil!.label.should eq("cached")
      W6LookupPlain.find(plain.id).not_nil!.label.should eq("cached")
      Grant::QueryCache.current?.not_nil!.hits.should eq(1)
    end
  end

  it "reads inside an open transaction" do
    plain = W6LookupPlain.create!(label: "tx")

    W6LookupPlain.transaction do
      W6LookupPlain.find(plain.id).not_nil!.label.should eq("tx")
    end
  end

  it "tags the statement when query logs are on, as the relation does" do
    plain = W6LookupPlain.create!(label: "tagged")
    W6LookupPlain.find(plain.id) # builds and keeps the untagged statement

    previously_enabled = Grant::QueryLogs.enabled?
    Grant::QueryLogs.enabled = true
    begin
      Grant::QueryLogs.with_context(request: "find") do
        W6LookupPlain.find(plain.id).not_nil!.label.should eq("tagged")
      end
    ensure
      Grant::QueryLogs.enabled = previously_enabled
    end
  end
end

describe "Shared empty clause lists" do
  it "stay empty however relations are built and chained" do
    base = W6LookupPlain.all
    chained = base.where(label: "a").order(:id).limit(3).offset(1).group_by(:label).having("COUNT(*) > ?", 0)
    chained.where(label: "b").distinct.assembler.select.raw_sql

    base.where!(label: "c")
    base.order!(:label)
    W6LookupPlain.where(label: "x").or(&.where(label: "y"))
    W6LookupPlain.where(label: "x").merge(W6LookupPlain.order(:id))
    W6LookupPlain.where(label: "z").unscope(:where).to_a
    W6LookupPlain.order(:id).reorder(:label).reverse_order.to_a
    W6LookupPlain.where(label: "q").pick(:label)

    Grant::Query::EmptyClauses.untouched?.should be_true
  end

  it "give a relation its own list on the first write" do
    first = W6LookupPlain.where(label: "one")
    second = W6LookupPlain.where(label: "two")

    first.where_fields.size.should eq(1)
    second.where_fields.size.should eq(1)
    first.where_fields.should_not be(second.where_fields)
    W6LookupPlain.all.where_fields.should be_empty
  end
end
