require "../../spec_helper"
require "../sti/sti_behavior_models"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class EqualityPerson < Grant::Base
    connection {{ adapter_literal }}
    table equality_people

    column id : Int64, primary: true
    column name : String?
  end

  class EqualityPet < Grant::Base
    connection {{ adapter_literal }}
    table equality_pets

    column id : Int64, primary: true
    column name : String?
  end
{% end %}

EqualityPerson.migrator.drop_and_create
EqualityPet.migrator.drop_and_create

describe "Record equality and hashing" do
  before_each do
    EqualityPerson.clear
    EqualityPet.clear
  end

  it "treats two instances loaded from the same row as equal" do
    person = EqualityPerson.create!(name: "Ada")
    first = EqualityPerson.find!(person.id)
    second = EqualityPerson.find!(person.id)

    first.same?(second).should be_false
    (first == second).should be_true
    (first == person).should be_true
    first.hash.should eq(second.hash)
  end

  it "treats different rows as unequal" do
    ada = EqualityPerson.create!(name: "Ada")
    grace = EqualityPerson.create!(name: "Grace")
    (ada == grace).should be_false
    (ada != grace).should be_true
  end

  it "keeps new records unequal to each other but equal to themselves" do
    first = EqualityPerson.new(name: "Ada")
    second = EqualityPerson.new(name: "Ada")
    (first == second).should be_false
    (first == first).should be_true
    first.hash.should_not eq(second.hash)
  end

  it "does not equate a new record with a saved one" do
    saved = EqualityPerson.create!(name: "Ada")
    fresh = EqualityPerson.new(name: "Ada")
    (fresh == saved).should be_false
    (saved == fresh).should be_false
  end

  it "does not equate different classes that share a primary key value" do
    person = EqualityPerson.create!(name: "Ada")
    pet = EqualityPet.create!(name: "Ada")
    person.id.should eq(pet.id)
    (person == pet).should be_false
  end

  it "does not equate a record with a non-record" do
    person = EqualityPerson.create!(name: "Ada")
    (person == "Ada").should be_false
    (person == nil).should be_false
  end

  it "collapses duplicates in a Set" do
    person = EqualityPerson.create!(name: "Ada")
    records = Set(EqualityPerson).new
    records << EqualityPerson.find!(person.id)
    records << EqualityPerson.find!(person.id)
    records << EqualityPerson.new(name: "x")
    records << EqualityPerson.new(name: "x")
    records.size.should eq(3)
  end

  it "works with uniq, includes? and Hash keys" do
    person = EqualityPerson.create!(name: "Ada")
    grace = EqualityPerson.create!(name: "Grace")
    loaded = [EqualityPerson.find!(person.id), EqualityPerson.find!(person.id), EqualityPerson.find!(grace.id)]

    loaded.uniq.size.should eq(2)
    loaded.includes?(person).should be_true
    (loaded - [person]).size.should eq(1)

    counts = {} of EqualityPerson => Int32
    loaded.each { |record| counts[record] = (counts[record]? || 0) + 1 }
    counts[person].should eq(2)
    counts[grace].should eq(1)
  end

  it "changes hash once a new record is saved, like ActiveRecord" do
    person = EqualityPerson.new(name: "Ada")
    before = person.hash
    person.save!
    person.hash.should_not eq(before)
    person.hash.should eq(EqualityPerson.find!(person.id).hash)
  end

  it "ignores unsaved attribute changes" do
    person = EqualityPerson.create!(name: "Ada")
    edited = EqualityPerson.find!(person.id)
    edited.name = "Changed"
    (edited == person).should be_true
  end

  describe "single table inheritance" do
    before_each do
      setup_behavior_sti_tables
      clear_behavior_sti_tables
    end

    it "compares by the STI base class" do
      admin = BehaviorAdminPersona.create!(name: "Root")
      as_base = admin.becomes(BehaviorPersona)
      as_base.should be_a(BehaviorPersona)
      as_base.class.should eq(BehaviorPersona)
      (admin == as_base).should be_true
      (as_base == admin).should be_true
      admin.hash.should eq(as_base.hash)
    end

    it "keeps sibling subclasses with different ids unequal" do
      admin = BehaviorAdminPersona.create!(name: "Root")
      member = BehaviorMemberPersona.create!(name: "Guest")
      (admin == member).should be_false
    end
  end
end
