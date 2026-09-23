require "../../spec_helper"

{% if ["pg", "sqlite", "mysql"].includes? env("CURRENT_ADAPTER") %}
  describe "timestamps" do
    it "should uses UTC for created_at by default" do
      parent = Parent.new(name: "parent").tap(&.save)
      found_parent = Parent.find!(parent.id)

      original_timestamp = parent.created_at!
      read_timestamp = found_parent.created_at!

      original_timestamp.location.should eq Time::Location::UTC
      read_timestamp.location.should eq Time::Location::UTC
    end

    it "should uses UTC for updated_at by default" do
      parent = Parent.new(name: "parent").tap(&.save)
      found_parent = Parent.find!(parent.id)

      original_timestamp = parent.updated_at!
      read_timestamp = found_parent.updated_at!

      original_timestamp.location.should eq Time::Location::UTC
      read_timestamp.location.should eq Time::Location::UTC
    end

    it "should uses timezone for created_at" do
      Grant.settings.default_timezone = "Asia/Shanghai"

      parent = Parent.new(name: "parent").tap(&.save)
      found_parent = Parent.find!(parent.id)

      original_timestamp = parent.created_at!
      read_timestamp = found_parent.created_at!

      original_timestamp.location.should eq Time::Location.load("Asia/Shanghai")
      read_timestamp.location.should eq Time::Location.load("Asia/Shanghai")
    end

    it "should uses timezone for updated_at" do
      Grant.settings.default_timezone = "Asia/Shanghai"

      parent = Parent.new(name: "parent").tap(&.save)
      found_parent = Parent.find!(parent.id)

      original_timestamp = parent.updated_at!
      read_timestamp = found_parent.updated_at!

      original_timestamp.location.should eq Time::Location.load("Asia/Shanghai")
      read_timestamp.location.should eq Time::Location.load("Asia/Shanghai")
    end

    it "preserves microseconds in created_at" do
      timestamp = Time.utc(2020, 1, 1) + 123_456.microseconds
      parent = Parent.new(name: "parent")
      parent.set_timestamps(to: timestamp)
      parent.save!(skip_timestamps: true)
      found_parent = Parent.find!(parent.id)

      read_timestamp = found_parent.created_at!

      read_timestamp.should eq timestamp
    end

    it "preserves microseconds in updated_at" do
      timestamp = Time.utc(2020, 1, 1) + 654_321.microseconds
      parent = Parent.new(name: "parent")
      parent.set_timestamps(to: timestamp)
      parent.save!(skip_timestamps: true)
      found_parent = Parent.find!(parent.id)

      read_timestamp = found_parent.updated_at!

      read_timestamp.should eq timestamp
    end

    context "bulk imports" do
      it "timestamps are returned correctly with bulk imports" do
        to_import = [
          Parent.new(name: "ParentImport1"),
          Parent.new(name: "ParentImport2"),
          Parent.new(name: "ParentImport3"),
        ]

        grandma = Parent.new(name: "grandma").tap(&.save)
        found_grandma = Parent.find! grandma.id
        Parent.import(to_import)

        parents = Parent.all("WHERE name LIKE ?", ["ParentImport%"])

        parents.size.should eq 3

        parents.each do |parent|
          parent.updated_at.not_nil!.location.should eq Time::Location::UTC
          parent.created_at.not_nil!.location.should eq Time::Location::UTC
          parent.updated_at.not_nil!.should be_close(found_grandma.updated_at.not_nil!, 1.second)
          parent.created_at.not_nil!.should be_close(found_grandma.created_at.not_nil!, 1.second)
        end
      end

      it "created_at and updated_at are correctly handled" do
        to_import = [
          Parent.new(name: "ParentOne"),
        ]

        Parent.import(to_import)
        parent1 = Parent.find_by!(name: "ParentOne")
        parent1.name.should eq "ParentOne"
        import_time = parent1.created_at!
        parent1.updated_at!.should eq import_time

        to_update = Parent.all("WHERE name = ?", ["ParentOne"])
        to_update.each { |parent| parent.name = "ParentOneEdited" }

        Parent.import(to_update, update_on_duplicate: true, columns: ["name"])

        parent1_edited = Parent.find_by!(name: "ParentOneEdited")
        parent1_edited.name.should eq "ParentOneEdited"
        parent1_edited.created_at!.should eq import_time
        parent1_edited.updated_at!.should be > import_time
      end
    end
  end
{% end %}
