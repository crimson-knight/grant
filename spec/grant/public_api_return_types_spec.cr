require "../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

class PublicApiReturnTypeBook < Grant::Base
  connection {{ adapter_literal }}

  column id : Int64, primary: true
  column author_id : Int64
  column owner_id : Int64
  column owner_type : String
  column title : String
end

class PublicApiReturnTypeAuthor < Grant::Base
  connection {{ adapter_literal }}

  column id : Int64, primary: true
  column name : String

  has_many :books, class_name: PublicApiReturnTypeBook, foreign_key: :author_id
  has_many :owned_books, class_name: PublicApiReturnTypeBook, as: :owner
end

class PublicApiReturnTypeCompositeEntry < Grant::Base
  connection {{ adapter_literal }}

  column id : Int64, primary: true
  column tenant_id : Int64
  column owner_id : Int64
  column title : String
end

class PublicApiReturnTypeCompositeOwner < Grant::Base
  include Grant::CompositePrimaryKey
  connection {{ adapter_literal }}

  column tenant_id : Int64, primary: true, auto: false
  column id : Int64, primary: true, auto: false
  composite_primary_key tenant_id, id

  has_many :entries, class_name: PublicApiReturnTypeCompositeEntry, foreign_key: {:tenant_id, :owner_id}
end
{% end %}

alias PublicApiRawScalarType = (Array(PG::BoolArray) | Array(PG::CharArray) | Array(PG::Float32Array) | Array(PG::Float64Array) |
                                Array(PG::Int16Array) | Array(PG::Int32Array) | Array(PG::Int64Array) | Array(PG::NumericArray) |
                                Array(PG::StringArray) | Array(PG::TimeArray) | Array(PG::UUIDArray) | Bool | Char | Float32 | Float64 |
                                Int16 | Int32 | Int64 | Int8 | JSON::Any | JSON::PullParser | PG::Geo::Box | PG::Geo::Circle |
                                PG::Geo::Line | PG::Geo::LineSegment | PG::Geo::Path | PG::Geo::Point | PG::Geo::Polygon |
                                PG::Interval | PG::Numeric | Slice(UInt8) | String | Time | Time::Span | UInt32 | UInt64 | UUID)?

describe "Grant public API inferred return types" do
  it "preserves the class query API return types" do
    typeof(PublicApiReturnTypeAuthor.all).to_s.should eq(Grant::Query::Builder(PublicApiReturnTypeAuthor).to_s)
    typeof(PublicApiReturnTypeAuthor.all("JOIN books ON books.author_id = authors.id")).to_s.should eq("(Array(PublicApiReturnTypeAuthor) | Grant::Collection(PublicApiReturnTypeAuthor))")
    typeof(PublicApiReturnTypeAuthor.all("WHERE name = ?", ["Ada"] of Grant::Columns::Type)).to_s.should eq("(Array(PublicApiReturnTypeAuthor) | Grant::Collection(PublicApiReturnTypeAuthor))")
    typeof(PublicApiReturnTypeAuthor.first).to_s.should eq(PublicApiReturnTypeAuthor?.to_s)
    typeof(PublicApiReturnTypeAuthor.first!).to_s.should eq(PublicApiReturnTypeAuthor.to_s)
    typeof(PublicApiReturnTypeAuthor.find(1_i64)).to_s.should eq(PublicApiReturnTypeAuthor?.to_s)
    typeof(PublicApiReturnTypeAuthor.find!(1_i64)).to_s.should eq(PublicApiReturnTypeAuthor.to_s)

    typeof(PublicApiReturnTypeAuthor.find_by(name: "Ada")).to_s.should eq(PublicApiReturnTypeAuthor?.to_s)
    typeof(PublicApiReturnTypeAuthor.find_by({"name" => "Ada"})).to_s.should eq(PublicApiReturnTypeAuthor?.to_s)
    typeof(PublicApiReturnTypeAuthor.find_by!(name: "Ada")).to_s.should eq(PublicApiReturnTypeAuthor.to_s)
    typeof(PublicApiReturnTypeAuthor.find_by!({"name" => "Ada"})).to_s.should eq(PublicApiReturnTypeAuthor.to_s)
    typeof(PublicApiReturnTypeAuthor.sole).to_s.should eq(PublicApiReturnTypeAuthor.to_s)
    typeof(PublicApiReturnTypeAuthor.find_sole_by(name: "Ada")).to_s.should eq(PublicApiReturnTypeAuthor.to_s)
    typeof(PublicApiReturnTypeAuthor.find_sole_by({"name" => "Ada"})).to_s.should eq(PublicApiReturnTypeAuthor.to_s)

    typeof(PublicApiReturnTypeAuthor.find_each(&.name)).to_s.should eq(Nil.to_s)
    typeof(PublicApiReturnTypeAuthor.find_in_batches(&.size)).to_s.should eq(Nil.to_s)
    # `query` stays undeclared: it returns the query log wrapper's result, which varies with the logging setup.
    typeof(PublicApiReturnTypeAuthor.scalar("SELECT 1")).to_s.should eq(PublicApiRawScalarType.to_s)
    typeof(PublicApiReturnTypeAuthor.scalar("SELECT 1") { |value| value.try(&.to_s) }).to_s.should eq(String?.to_s)
    typeof(PublicApiReturnTypeAuthor.scalar("SELECT ?", [1_i64] of Grant::Columns::Type) { |value| value.try(&.to_s) }).to_s.should eq(String?.to_s)
    typeof(PublicApiReturnTypeAuthor.new.reload).to_s.should eq(PublicApiReturnTypeAuthor.to_s)
  end

  it "preserves every model where overload return type" do
    typeof(PublicApiReturnTypeAuthor.where(name: "Ada")).to_s.should eq(Grant::Query::Builder(PublicApiReturnTypeAuthor).to_s)
    typeof(PublicApiReturnTypeAuthor.where({"name" => "Ada"})).to_s.should eq(Grant::Query::Builder(PublicApiReturnTypeAuthor).to_s)
    typeof(PublicApiReturnTypeAuthor.where(:name, :eq, "Ada")).to_s.should eq(Grant::Query::Builder(PublicApiReturnTypeAuthor).to_s)
    typeof(PublicApiReturnTypeAuthor.where("name = ?", "Ada")).to_s.should eq(Grant::Query::Builder(PublicApiReturnTypeAuthor).to_s)
    typeof(PublicApiReturnTypeAuthor.where("name = ? OR name = ?", "Ada", "Grace")).to_s.should eq(Grant::Query::Builder(PublicApiReturnTypeAuthor).to_s)
    typeof(PublicApiReturnTypeAuthor.where).to_s.should eq(Grant::Query::WhereChain(PublicApiReturnTypeAuthor).to_s)
  end

  it "preserves the lazy collection and transaction API return types" do
    typeof(Grant::Collection(PublicApiReturnTypeAuthor).new(-> { [] of PublicApiReturnTypeAuthor })).to_s.should eq(Grant::Collection(PublicApiReturnTypeAuthor).to_s)
    typeof(Grant::Collection(PublicApiReturnTypeAuthor).new(-> { [] of PublicApiReturnTypeAuthor }).loaded?).to_s.should eq(Bool.to_s)
    typeof(Grant::RecordDestroyedError.new("Author", "save")).to_s.should eq(Grant::RecordDestroyedError.to_s)

    # `clear` stays undeclared: it returns whatever the adapter's query log returns, which varies with the logging setup.
    typeof(PublicApiReturnTypeAuthor.create(name: "Ada")).to_s.should eq(PublicApiReturnTypeAuthor.to_s)
    typeof(PublicApiReturnTypeAuthor.create({"name" => "Ada"})).to_s.should eq(PublicApiReturnTypeAuthor.to_s)
    typeof(PublicApiReturnTypeAuthor.create!(name: "Ada")).to_s.should eq(PublicApiReturnTypeAuthor.to_s)
    typeof(PublicApiReturnTypeAuthor.create!({"name" => "Ada"})).to_s.should eq(PublicApiReturnTypeAuthor.to_s)
    typeof(PublicApiReturnTypeAuthor.import([] of PublicApiReturnTypeAuthor)).to_s.should eq(Nil.to_s)
    typeof(PublicApiReturnTypeAuthor.import(Grant::Collection(PublicApiReturnTypeAuthor).new(-> { [] of PublicApiReturnTypeAuthor }))).to_s.should eq(Nil.to_s)
    typeof(PublicApiReturnTypeAuthor.import([] of PublicApiReturnTypeAuthor, update_on_duplicate: true, columns: ["name"])).to_s.should eq(Nil.to_s)
    typeof(PublicApiReturnTypeAuthor.import([] of PublicApiReturnTypeAuthor, ignore_on_duplicate: true)).to_s.should eq(Nil.to_s)
  end

  it "preserves generated association reader return types" do
    author = PublicApiReturnTypeAuthor.new
    typeof(author.books).to_s.should eq(Grant::AssociationCollection(PublicApiReturnTypeAuthor, PublicApiReturnTypeBook).to_s)
    typeof(author.reload_books).to_s.should eq(Grant::AssociationCollection(PublicApiReturnTypeAuthor, PublicApiReturnTypeBook).to_s)
    typeof(author.owned_books).to_s.should eq(Grant::AssociationCollection(PublicApiReturnTypeAuthor, PublicApiReturnTypeBook).to_s)
    typeof(author.reload_owned_books).to_s.should eq(Grant::AssociationCollection(PublicApiReturnTypeAuthor, PublicApiReturnTypeBook).to_s)

    composite_owner = PublicApiReturnTypeCompositeOwner.new(tenant_id: 1_i64, id: 1_i64)
    typeof(composite_owner.entries).to_s.should eq(Grant::CompositeCollection(PublicApiReturnTypeCompositeOwner, PublicApiReturnTypeCompositeEntry).to_s)
    typeof(composite_owner.reload_entries).to_s.should eq(Grant::CompositeCollection(PublicApiReturnTypeCompositeOwner, PublicApiReturnTypeCompositeEntry).to_s)
  end
end
