require "../../spec_helper"

{% begin %}
{% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

class InheritedLifecycleRoot < Grant::Base
  include Grant::STI
  connection {{ adapter_literal }}
  table grant_sti_inherited_lifecycle_records

  column id : Int64, primary: true
  column type : String
  column name : String?
  column callback_mark : String?

  validate :name, "is required" do |record|
    !record.name.to_s.blank?
  end

  before_save :set_root_callback_mark

  around_save do |block|
    self.callback_mark = "#{callback_mark}:root-around-before"
    block.call
    self.callback_mark = "#{callback_mark}:root-around-after"
  end

  private def set_root_callback_mark
    self.callback_mark = "#{callback_mark}:root"
  end
end

class InheritedLifecycleChild < InheritedLifecycleRoot
  before_save :append_child_callback_mark

  around_save do |block|
    self.callback_mark = "#{callback_mark}:child-around-before"
    block.call
    self.callback_mark = "#{callback_mark}:child-around-after"
  end

  private def append_child_callback_mark
    self.callback_mark = "#{callback_mark}:child"
  end
end
{% end %}

describe "Grant STI validation and callback inheritance" do
  before_all do
    InheritedLifecycleRoot.adapter.open do |db|
      db.exec "DROP TABLE IF EXISTS grant_sti_inherited_lifecycle_records"

      if CURRENT_ADAPTER == "pg"
        db.exec <<-SQL
          CREATE TABLE grant_sti_inherited_lifecycle_records (
            id BIGSERIAL PRIMARY KEY,
            type TEXT NOT NULL,
            name TEXT,
            callback_mark TEXT
          )
          SQL
      elsif CURRENT_ADAPTER == "mysql"
        db.exec <<-SQL
          CREATE TABLE grant_sti_inherited_lifecycle_records (
            id BIGINT AUTO_INCREMENT PRIMARY KEY,
            type VARCHAR(255) NOT NULL,
            name TEXT,
            callback_mark TEXT
          )
          SQL
      else
        db.exec <<-SQL
          CREATE TABLE grant_sti_inherited_lifecycle_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            name TEXT,
            callback_mark TEXT
          )
          SQL
      end
    end
  end

  before_each do
    InheritedLifecycleRoot.adapter.open do |db|
      db.exec "DELETE FROM grant_sti_inherited_lifecycle_records"
    end
  end

  it "runs root validations once on an STI child" do
    child = InheritedLifecycleChild.new(name: nil)

    child.valid?.should be_false
    child.errors.map(&.field.to_s).should eq ["name"]
    child.errors.size.should eq 1
    child.save.should be_false
    InheritedLifecycleRoot.count.should eq 0
  end

  it "runs root save callbacks before child callbacks" do
    child = InheritedLifecycleChild.new(name: "valid", callback_mark: "start")

    child.save.should be_true
    child.callback_mark.should eq(
      "start:root-around-before:child-around-before:root:child:child-around-after:root-around-after"
    )
    persisted_child = InheritedLifecycleChild.find!(child.id)

    persisted_child.callback_mark.should eq("start:root-around-before:child-around-before:root:child")
  end
end
