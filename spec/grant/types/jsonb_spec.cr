require "../../spec_helper"

class JsonbTypeDoc < Grant::Base
  connection {{ env("CURRENT_ADAPTER") || "sqlite" }}
  table jsonb_type_docs

  column id : Int64, primary: true
  column title : String?
  column settings : JSON::Any?
end

def jsonb_titles(relation)
  relation.order(:title).select.map(&.title)
end

describe "JSON document columns" do
  before_each do
    JsonbTypeDoc.migrator.drop_and_create
  end

  it "uses a native jsonb column on PostgreSQL and text on SQLite" do
    type = ""
    JsonbTypeDoc.adapter.open do |db|
      if CURRENT_ADAPTER == "pg"
        type = db.query_one("SELECT udt_name FROM information_schema.columns WHERE table_name = 'jsonb_type_docs' AND column_name = 'settings'", as: String)
      else
        db.query("PRAGMA table_info(jsonb_type_docs)") do |rs|
          rs.each do
            rs.read(Int32)
            name = rs.read(String)
            column_type = rs.read(String)
            type = column_type if name == "settings"
            rs.read(Int32); rs.read(String?); rs.read(Int32)
          end
        end
      end
    end
    type.downcase.should eq(CURRENT_ADAPTER == "pg" ? "jsonb" : "text")
  end

  it "round trips nested documents, scalars and NULL through the database" do
    document = JSON.parse(%({"theme":"dark","n":[1,2],"nested":{"a":{"b":true}},"none":null}))
    doc = JsonbTypeDoc.create!(title: "a", settings: document)
    reloaded = JsonbTypeDoc.find!(doc.id)
    reloaded.settings.should eq document
    reloaded.settings.not_nil!["nested"]["a"]["b"].as_bool.should be_true

    JsonbTypeDoc.create!(title: "null").settings.should be_nil
    JsonbTypeDoc.find!(JsonbTypeDoc.create!(title: "scalar", settings: JSON.parse("42")).id).settings.should eq JSON.parse("42")

    reloaded.settings = JSON.parse(%({"theme":"light"}))
    reloaded.save!
    JsonbTypeDoc.find!(doc.id).settings.not_nil!["theme"].as_s.should eq "light"
  end

  it "accepts a JSON string through mass assignment" do
    doc = JsonbTypeDoc.new
    doc.set_attributes({"settings" => %({"theme":"dark"})})
    doc.errors.should be_empty
    doc.settings.not_nil!["theme"].as_s.should eq "dark"
  end

  describe "predicates" do
    before_each do
      JsonbTypeDoc.create!(title: "dark", settings: JSON.parse(%({"theme":"dark","size":12,"beta":true,"tags":["a","b"],"ui":{"lang":"en","pins":[1,2]}})))
      JsonbTypeDoc.create!(title: "light", settings: JSON.parse(%({"theme":"light","size":14,"beta":false,"tags":["b","c"],"ui":{"lang":"de"}})))
      JsonbTypeDoc.create!(title: "empty", settings: JSON.parse(%({})))
      JsonbTypeDoc.create!(title: "none")
    end

    it "json_contains matches containment of objects, nested objects and arrays" do
      jsonb_titles(JsonbTypeDoc.where.json_contains(:settings, {theme: "dark"})).should eq ["dark"]
      jsonb_titles(JsonbTypeDoc.where.json_contains(:settings, {ui: {lang: "de"}})).should eq ["light"]
      jsonb_titles(JsonbTypeDoc.where.json_contains(:settings, {tags: ["b"]})).should eq ["dark", "light"]
      jsonb_titles(JsonbTypeDoc.where.json_contains(:settings, {tags: ["a", "b"]})).should eq ["dark"]
      jsonb_titles(JsonbTypeDoc.where.json_contains(:settings, {beta: true, size: 12})).should eq ["dark"]
      jsonb_titles(JsonbTypeDoc.where.json_contains(:settings, {ui: {pins: [2]}})).should eq ["dark"]
      jsonb_titles(JsonbTypeDoc.where.json_contains(:settings, JSON.parse(%({"theme":"light"})))).should eq ["light"]
      jsonb_titles(JsonbTypeDoc.where.json_contains(:settings, {theme: "missing"})).should be_empty
    end

    it "json_path compares the value at a path" do
      jsonb_titles(JsonbTypeDoc.where.json_path(:settings, "theme", "dark")).should eq ["dark"]
      jsonb_titles(JsonbTypeDoc.where.json_path(:settings, %w(ui lang), "de")).should eq ["light"]
      jsonb_titles(JsonbTypeDoc.where.json_path(:settings, "ui.lang", "en")).should eq ["dark"]
      jsonb_titles(JsonbTypeDoc.where.json_path(:settings, "size", 14)).should eq ["light"]
      jsonb_titles(JsonbTypeDoc.where.json_path(:settings, "beta", true)).should eq ["dark"]
      jsonb_titles(JsonbTypeDoc.where.json_path(:settings, %w(tags 0), "b")).should eq ["light"]
    end

    it "json_has_key matches a top-level key" do
      jsonb_titles(JsonbTypeDoc.where.json_has_key(:settings, "theme")).should eq ["dark", "light"]
      jsonb_titles(JsonbTypeDoc.where.json_has_key(:settings, "nope")).should be_empty
    end

    it "composes with ordinary conditions and does not mutate the receiver" do
      base = JsonbTypeDoc.where.json_has_key(:settings, "theme")
      jsonb_titles(base.where(title: "light")).should eq ["light"]
      jsonb_titles(base).should eq ["dark", "light"]
    end

    it "rejects a path segment that could break out of the SQLite path" do
      if CURRENT_ADAPTER == "sqlite"
        expect_raises(ArgumentError, /Invalid JSON path segment/) do
          JsonbTypeDoc.where.json_path(:settings, ["a\"b"], "x")
        end
      end
    end

    it "uses indexable operators" do
      sql = JsonbTypeDoc.where.json_contains(:settings, {theme: "dark"}).assembler.select.raw_sql
      sql.should contain("@>") if CURRENT_ADAPTER == "pg"
      sql.should contain("json_extract") if CURRENT_ADAPTER == "sqlite"
      path_sql = JsonbTypeDoc.where.json_path(:settings, "theme", "dark").assembler.select.raw_sql
      path_sql.should contain("#>>") if CURRENT_ADAPTER == "pg"
    end
  end
end
