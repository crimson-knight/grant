require "../../spec_helper"
require "../../support/association_query_counter"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class NiCountry < Grant::Base
    connection {{ adapter_literal }}
    table ni_countries
    column id : Int64, primary: true
    column name : String
    has_many :ni_cities, class_name: NiCity, foreign_key: :ni_country_id
    has_one :ni_flag, class_name: NiFlag, foreign_key: :ni_country_id
  end

  class NiCity < Grant::Base
    connection {{ adapter_literal }}
    table ni_cities
    column id : Int64, primary: true
    column name : String
    column ni_country_id : Int64?
    belongs_to :ni_country, class_name: NiCountry, foreign_key: :ni_country_id, optional: true
    has_many :ni_streets, class_name: NiStreet, foreign_key: :ni_city_id
    has_one :ni_mayor, class_name: NiMayor, foreign_key: :ni_city_id
  end

  class NiStreet < Grant::Base
    connection {{ adapter_literal }}
    table ni_streets
    column id : Int64, primary: true
    column name : String
    column ni_city_id : Int64?
    belongs_to :ni_city, class_name: NiCity, foreign_key: :ni_city_id, optional: true
    has_many :ni_houses, class_name: NiHouse, foreign_key: :ni_street_id
  end

  class NiHouse < Grant::Base
    connection {{ adapter_literal }}
    table ni_houses
    column id : Int64, primary: true
    column number : Int32
    column ni_street_id : Int64?
    belongs_to :ni_street, class_name: NiStreet, foreign_key: :ni_street_id, optional: true
  end

  class NiFlag < Grant::Base
    connection {{ adapter_literal }}
    table ni_flags
    column id : Int64, primary: true
    column colors : String
    column ni_country_id : Int64?
  end

  class NiMayor < Grant::Base
    connection {{ adapter_literal }}
    table ni_mayors
    column id : Int64, primary: true
    column name : String
    column ni_city_id : Int64?
  end
{% end %}

def seed_world(countries : Int32)
  countries.times do |c|
    country = NiCountry.create!(name: "country #{c}")
    NiFlag.create!(colors: "red #{c}", ni_country_id: country.id)
    2.times do |i|
      city = NiCity.create!(name: "city #{c}-#{i}", ni_country_id: country.id)
      NiMayor.create!(name: "mayor #{c}-#{i}", ni_city_id: city.id)
      2.times do |s|
        street = NiStreet.create!(name: "street #{c}-#{i}-#{s}", ni_city_id: city.id)
        2.times { |h| NiHouse.create!(number: h, ni_street_id: street.id) }
      end
    end
  end
end

describe "nested includes" do
  before_all do
    {% for model in [NiCountry, NiCity, NiStreet, NiHouse, NiFlag, NiMayor] %}
      {{ model }}.migrator.drop_and_create
    {% end %}
  end

  before_each do
    {% for model in [NiHouse, NiStreet, NiMayor, NiCity, NiFlag, NiCountry] %}
      {{ model }}.clear
    {% end %}
  end

  it "loads three levels with one query per level" do
    seed_world(3)

    countries = [] of NiCountry
    queries = AssociationQueryCounter.selects do
      countries = NiCountry.includes(ni_cities: {ni_streets: :ni_houses}).order(:id).select.to_a
    end
    queries.should eq(4)

    AssociationQueryCounter.selects do
      countries.each do |country|
        country.ni_cities.size.should eq(2)
        country.ni_cities.each do |city|
          city.ni_streets.size.should eq(2)
          city.ni_streets.each { |street| street.ni_houses.size.should eq(2) }
        end
      end
    end.should eq(0)
  end

  it "accepts arrays, siblings, and mixed forms at each level" do
    seed_world(2)

    countries = NiCountry.includes(:ni_flag, ni_cities: [:ni_mayor, {ni_streets: :ni_houses}]).order(:id).select
    countries.each do |country|
      country.association_loaded?(:ni_flag).should be_true
      country.ni_cities.each do |city|
        city.association_loaded?(:ni_mayor).should be_true
        city.ni_streets.each { |street| street.association_loaded?(:ni_houses).should be_true }
      end
    end
  end

  it "nests through preload and eager_load and on the class" do
    seed_world(1)

    NiCountry.preload(ni_cities: :ni_mayor).select.first.ni_cities.first!.association_loaded?(:ni_mayor).should be_true
    NiCountry.eager_load(ni_cities: :ni_streets).select.first.ni_cities.first!.association_loaded?(:ni_streets).should be_true
  end

  it "keeps the recursive shape in includes_associations" do
    relation = NiCountry.includes(ni_cities: {ni_streets: :ni_houses})
    relation.includes_associations.size.should eq(1)
    relation.includes_associations.first.should be_a(Hash(Symbol, Array(Grant::Includes)))
  end

  it "raises AssociationNotFoundError for a name that is not an association" do
    seed_world(1)
    expect_raises(Grant::AssociationNotFoundError, /'typo' was not found on NiCountry/) do
      NiCountry.includes(:typo).select.to_a
    end
    expect_raises(Grant::AssociationNotFoundError, /'nope' was not found on NiCity/) do
      NiCountry.includes(ni_cities: :nope).select.to_a
    end
    expect_raises(Grant::AssociationNotFoundError) { NiCountry.preload(:typo).select.to_a }
    expect_raises(Grant::AssociationNotFoundError) { NiCountry.eager_load(:typo) }
  end

  it "upgrades includes to a JOIN when a where names the association's table" do
    paris_country = NiCountry.create!(name: "france")
    NiCity.create!(name: "Paris", ni_country_id: paris_country.id)
    NiCity.create!(name: "Lyon", ni_country_id: paris_country.id)
    other = NiCountry.create!(name: "germany")
    NiCity.create!(name: "Berlin", ni_country_id: other.id)

    plain = NiCountry.includes(:ni_cities).order(:id).select
    plain.map { |country| country.ni_cities.size }.should eq([2, 1])

    relation = NiCountry.includes(:ni_cities).where("ni_cities.name", :eq, "Paris")
    countries = relation.select
    countries.map(&.name).should eq(["france"])
    countries.first.ni_cities.map(&.name).should eq(["Paris"])
  end

  it "keeps every row of the association when the where has an OR" do
    france = NiCountry.create!(name: "france")
    NiCity.create!(name: "Paris", ni_country_id: france.id)
    NiCity.create!(name: "Lyon", ni_country_id: france.id)
    germany = NiCountry.create!(name: "germany")
    NiCity.create!(name: "Berlin", ni_country_id: germany.id)

    countries = NiCountry.includes(:ni_cities)
      .where("ni_countries.name", :eq, "germany")
      .or("ni_cities.name", :eq, "Paris")
      .order(:id).select
    countries.map(&.name).should eq(["france", "germany"])
    countries.first.ni_cities.map(&.name).sort!.should eq(["Lyon", "Paris"])
    countries.last.ni_cities.map(&.name).should eq(["Berlin"])
  end

  it "matches the same restriction with an explicit eager_load" do
    country = NiCountry.create!(name: "france")
    NiCity.create!(name: "Paris", ni_country_id: country.id)
    NiCity.create!(name: "Lyon", ni_country_id: country.id)

    countries = NiCountry.eager_load(:ni_cities).where("ni_cities.name", :eq, "Lyon").select
    countries.first.ni_cities.map(&.name).should eq(["Lyon"])
  end
end
