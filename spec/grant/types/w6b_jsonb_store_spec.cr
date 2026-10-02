require "../../spec_helper"
require "../../support/column_type"
require "json"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6bJsonDoc < Grant::Base
    connection {{ adapter_literal }}
    table w6b_json_docs

    column id : Int64, primary: true
    column title : String?
    column data : JSON::Any?, type: :jsonb

    store_accessor :data, theme : String = "light", size : Int32 = 10, beta : Bool = false, ratio : Float64?, big : Int64?, extra : JSON::Any?
    store_accessor :data, locale : String?, prefix: true
  end
{% end %}

private def w6b_json_titles(relation) : Array(String?)
  relation.order(:title).select.map(&.title)
end

describe "JSON documents: type, store_accessor and in-place mutation" do
  before_all do
    W6bJsonDoc.migrator.drop_and_create
  end

  before_each do
    W6bJsonDoc.clear
  end

  describe "type: :jsonb" do
    it "stores a native jsonb column on PostgreSQL, json on MySQL and JSON text on SQLite" do
      expected = {"pg" => "jsonb", "mysql" => "json"}[CURRENT_ADAPTER]? || "text"
      database_column_type(W6bJsonDoc.adapter, "w6b_json_docs", "data").should eq expected
    end

    it "round trips a document" do
      document = JSON.parse(%({"a":{"b":[1,2,{"c":true}]},"n":null}))
      doc = W6bJsonDoc.create!(title: "x", data: document)
      W6bJsonDoc.find!(doc.id).data.should eq document
    end
  end

  describe "store_accessor on a JSON column" do
    it "reads defaults without building the document" do
      doc = W6bJsonDoc.new
      doc.theme.should eq("light")
      doc.size.should eq(10)
      doc.beta.should be_false
      doc.beta?.should be_false
      doc.ratio.should be_nil
      doc.data.should be_nil
    end

    it "writes typed keys, keeps the other keys and persists" do
      doc = W6bJsonDoc.new(title: "a", data: JSON.parse(%({"keep":"me"})))
      doc.theme = "dark"
      doc.size = 14
      doc.beta = true
      doc.ratio = 0.5
      doc.big = 9_000_000_000_i64
      doc.extra = JSON.parse(%({"k":[1,2]}))
      doc.data_locale = "en"
      doc.save!

      loaded = W6bJsonDoc.find!(doc.id)
      loaded.theme.should eq("dark")
      loaded.size.should eq(14)
      loaded.beta?.should be_true
      loaded.ratio.should eq(0.5)
      loaded.big.should eq(9_000_000_000_i64)
      loaded.extra.not_nil!["k"][1].as_i.should eq(2)
      loaded.data_locale.should eq("en")
      loaded.data.not_nil!["keep"].as_s.should eq("me")
    end

    it "falls back to the default for a missing or mistyped key" do
      doc = W6bJsonDoc.create!(title: "a", data: JSON.parse(%({"theme":5,"size":"x"})))
      loaded = W6bJsonDoc.find!(doc.id)
      loaded.theme.should eq("light")
      loaded.size.should eq(10)
    end

    it "writes nil as a JSON null" do
      doc = W6bJsonDoc.create!(title: "a", data: JSON.parse(%({"ratio":1.5})))
      doc.ratio = nil
      doc.save!
      loaded = W6bJsonDoc.find!(doc.id)
      loaded.ratio.should be_nil
      loaded.data.not_nil!.as_h.has_key?("ratio").should be_true
    end

    it "tracks dirty state per key and resets after save" do
      doc = W6bJsonDoc.create!(title: "a", data: JSON.parse(%({"theme":"light"})))
      doc.theme_changed?.should be_false
      doc.theme = "dark"
      doc.theme_changed?.should be_true
      doc.theme_was.should eq("light")
      doc.size_changed?.should be_false
      doc.data_changed?.should be_true
      doc.theme = "light"
      doc.theme_changed?.should be_false
      doc.theme = "dark"
      doc.save!
      doc.theme_changed?.should be_false
      doc.data_changed?.should be_false
    end

    it "builds on a document that was never set" do
      doc = W6bJsonDoc.new(title: "n")
      doc.theme = "dark"
      doc.save!
      W6bJsonDoc.find!(doc.id).data.not_nil!["theme"].as_s.should eq("dark")
    end
  end

  describe "in-place mutation" do
    it "sees an edit of a nested value made without the setter" do
      doc = W6bJsonDoc.create!(title: "a", data: JSON.parse(%({"tags":["x"],"n":1})))
      loaded = W6bJsonDoc.find!(doc.id)
      loaded.data_changed?.should be_false
      loaded.has_changes_to_save?.should be_false

      loaded.data.not_nil!.as_h["n"] = JSON::Any.new(2_i64)
      loaded.data_changed?.should be_true
      loaded.has_changes_to_save?.should be_true
      loaded.changed.should contain("data")
    end

    it "persists an in-place edit on save and then reads clean" do
      doc = W6bJsonDoc.create!(title: "a", data: JSON.parse(%({"tags":["x"]})))
      loaded = W6bJsonDoc.find!(doc.id)
      loaded.data.not_nil!["tags"].as_a << JSON::Any.new("y")
      loaded.save!

      loaded.data_changed?.should be_false
      W6bJsonDoc.find!(doc.id).data.not_nil!["tags"].as_a.map(&.as_s).should eq(["x", "y"])

      loaded.data.not_nil!.as_h["extra"] = JSON::Any.new(true)
      loaded.save!
      W6bJsonDoc.find!(doc.id).data.not_nil!["extra"].as_bool.should be_true
    end

    it "is not fooled by key order or whitespace of the stored document" do
      doc = W6bJsonDoc.create!(title: "a", data: JSON.parse(%({"b":1,   "a":2})))
      W6bJsonDoc.find!(doc.id).data_changed?.should be_false
    end

    it "writes nothing for an unchanged record" do
      doc = W6bJsonDoc.create!(title: "a", data: JSON.parse(%({"a":1})))
      loaded = W6bJsonDoc.find!(doc.id)
      backend = Log::MemoryBackend.new
      Log.builder.bind("db.*", Log::Severity::Debug, backend)
      begin
        loaded.save!
      ensure
        Log.builder.unbind("db.*", Log::Severity::Debug, backend)
      end
      backend.entries.compact_map { |entry| entry.data[:query]?.try(&.as_s?) }.none?(&.starts_with?("UPDATE")).should be_true
    end
  end

  describe "where(data: {a: 1}) shorthand" do
    before_each do
      W6bJsonDoc.create!(title: "dark", data: JSON.parse(%({"theme":"dark","size":12,"beta":true,"tags":["a","b"],"ui":{"lang":"en"}})))
      W6bJsonDoc.create!(title: "light", data: JSON.parse(%({"theme":"light","size":14,"beta":false,"tags":["b","c"],"ui":{"lang":"de"}})))
      W6bJsonDoc.create!(title: "empty", data: JSON.parse(%({})))
      W6bJsonDoc.create!(title: "none")
    end

    it "matches containment of a named tuple" do
      w6b_json_titles(W6bJsonDoc.where(data: {theme: "dark"})).should eq(["dark"])
      w6b_json_titles(W6bJsonDoc.where(data: {ui: {lang: "de"}})).should eq(["light"])
      w6b_json_titles(W6bJsonDoc.where(data: {tags: ["b"]})).should eq(["dark", "light"])
      w6b_json_titles(W6bJsonDoc.where(data: {beta: true, size: 12})).should eq(["dark"])
      w6b_json_titles(W6bJsonDoc.where(data: {theme: "missing"})).should be_empty
    end

    it "accepts a hash and composes with other conditions, or and chaining" do
      w6b_json_titles(W6bJsonDoc.where(data: {"theme" => "light"})).should eq(["light"])
      w6b_json_titles(W6bJsonDoc.where(title: "dark").where(data: {theme: "dark"})).should eq(["dark"])
      w6b_json_titles(W6bJsonDoc.where(title: "light").where(data: {theme: "dark"})).should be_empty
      w6b_json_titles(W6bJsonDoc.where(data: {theme: "dark"}).or(W6bJsonDoc.where(data: {theme: "light"}))).should eq(["dark", "light"])
    end

    it "compiles to the indexable operator, never a Crystal-side filter" do
      sql = W6bJsonDoc.where(data: {theme: "dark"}).assembler.select.raw_sql
      sql.should contain("@>") if CURRENT_ADAPTER == "pg"
      sql.should contain("json_extract") if CURRENT_ADAPTER == "sqlite"
      sql.should contain("JSON_CONTAINS") if CURRENT_ADAPTER == "mysql"
    end

    it "still treats a name that is not a JSON column as a joined table" do
      expect_raises(ArgumentError, /Unknown table/) { W6bJsonDoc.where(nothing: {a: 1}) }
    end
  end

  describe "containment of objects inside arrays" do
    before_each do
      W6bJsonDoc.create!(title: "orders", data: JSON.parse(%({"items":[{"sku":"a","qty":1,"opts":{"gift":true}},{"sku":"b","qty":2}],"matrix":[[1,2],[3]]})))
      W6bJsonDoc.create!(title: "other", data: JSON.parse(%({"items":[{"sku":"c","qty":1}],"matrix":[[9]]})))
      W6bJsonDoc.create!(title: "scalars", data: JSON.parse(%({"items":["a","b"]})))
    end

    it "matches an object element by a subset of its keys" do
      w6b_json_titles(W6bJsonDoc.where.json_contains(:data, {items: [{sku: "a"}]})).should eq(["orders"])
      w6b_json_titles(W6bJsonDoc.where.json_contains(:data, {items: [{sku: "b", qty: 2}]})).should eq(["orders"])
      w6b_json_titles(W6bJsonDoc.where.json_contains(:data, {items: [{sku: "b", qty: 1}]})).should be_empty
      w6b_json_titles(W6bJsonDoc.where.json_contains(:data, {items: [{qty: 1}]})).should eq(["orders", "other"])
    end

    it "matches several elements, nested objects and nested arrays" do
      w6b_json_titles(W6bJsonDoc.where.json_contains(:data, {items: [{sku: "a"}, {sku: "b"}]})).should eq(["orders"])
      w6b_json_titles(W6bJsonDoc.where.json_contains(:data, {items: [{opts: {gift: true}}]})).should eq(["orders"])
      w6b_json_titles(W6bJsonDoc.where.json_contains(:data, {matrix: [[1]]})).should eq(["orders"])
      w6b_json_titles(W6bJsonDoc.where.json_contains(:data, {matrix: [[3], [2]]})).should eq(["orders"])
      w6b_json_titles(W6bJsonDoc.where.json_contains(:data, {items: ["a"]})).should eq(["scalars"])
    end
  end
end
