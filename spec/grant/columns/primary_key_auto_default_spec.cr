require "../../spec_helper"

class PrimaryKeyAutoDefaultSlug < Grant::Base
  connection {{ env("CURRENT_ADAPTER") || "sqlite" }}
  table primary_key_auto_default_slugs

  column id : String, primary: true
  column title : String?
end

class PrimaryKeyAutoDefaultCounter < Grant::Base
  connection {{ env("CURRENT_ADAPTER") || "sqlite" }}
  table primary_key_auto_default_counters

  column id : Int64, primary: true
  column title : String?
end

class PrimaryKeyAutoExplicitCounter < Grant::Base
  connection {{ env("CURRENT_ADAPTER") || "sqlite" }}
  table primary_key_auto_explicit_counters

  column id : Int64, primary: true, auto: true
  column title : String?
end

class PrimaryKeyAutoExplicitOff < Grant::Base
  connection {{ env("CURRENT_ADAPTER") || "sqlite" }}
  table primary_key_auto_explicit_offs

  column id : Int64, primary: true, auto: false
  column title : String?
end

describe "primary key auto default" do
  it "does not auto-generate a String primary key" do
    PrimaryKeyAutoDefaultSlug.migrator.drop_and_create

    slug = PrimaryKeyAutoDefaultSlug.new(title: "First")
    slug.id = "first-post"
    slug.save!

    PrimaryKeyAutoDefaultSlug.find!("first-post").title.should eq "First"
  end

  it "still auto-generates an integer primary key" do
    PrimaryKeyAutoDefaultCounter.migrator.drop_and_create

    counter = PrimaryKeyAutoDefaultCounter.create!(title: "One")

    counter.id.should_not be_nil
    PrimaryKeyAutoDefaultCounter.find!(counter.id).title.should eq "One"
  end

  it "honors an explicit auto: true" do
    PrimaryKeyAutoExplicitCounter.migrator.drop_and_create

    counter = PrimaryKeyAutoExplicitCounter.create!(title: "One")

    counter.id.should_not be_nil
    PrimaryKeyAutoExplicitCounter.find!(counter.id).title.should eq "One"
  end

  it "honors an explicit auto: false" do
    PrimaryKeyAutoExplicitOff.migrator.drop_and_create

    record = PrimaryKeyAutoExplicitOff.new(title: "Chosen")
    record.id = 42_i64
    record.save!

    PrimaryKeyAutoExplicitOff.find!(42_i64).title.should eq "Chosen"
  end
end
