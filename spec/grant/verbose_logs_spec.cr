require "../spec_helper"
require "log/spec"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class VlWidget < Grant::Base
    connection {{ adapter_literal }}
    table vl_widgets

    column id : Int64, primary: true
    column label : String
  end
{% end %}

# Messages written to the grant.sql source while the block runs, at *level*.
private def sql_messages(level : Log::Severity = Log::Severity::Debug, & : ->) : Array(String)
  backend = Log::MemoryBackend.new
  Log.builder.bind("grant.sql", level, backend)
  begin
    yield
  ensure
    Log.builder.unbind("grant.sql", level, backend)
  end
  backend.entries.compact_map(&.message)
end

describe Grant::Logs do
  before_all do
    VlWidget.migrator.drop_and_create
  end

  before_each do
    VlWidget.clear
    Grant::Logs.verbose_query_logs = false
  end

  after_each do
    Grant::Logs.verbose_query_logs = false
  end

  describe ".verbose_query_logs" do
    it "is off by default and adds no label or location" do
      messages = sql_messages { VlWidget.all.to_a }

      messages.should_not be_empty
      messages.none?(&.includes?("↳")).should be_true
      messages.none?(&.starts_with?("VlWidget Load")).should be_true
    end

    it "adds a labeled line with the calling file and line at debug level" do
      Grant::Logs.verbose_query_logs = true

      line = 0
      messages = sql_messages do
        line = __LINE__ + 1
        VlWidget.all.to_a
      end

      verbose = messages.find!(&.includes?("↳"))
      verbose.should match(/\AVlWidget Load \(\d+(\.\d+)?ms\)  ↳ /)
      verbose.should contain("spec/grant/verbose_logs_spec.cr:#{line}")
      verbose.should_not contain("src/adapter")
      verbose.should_not contain("src/grant/")
    end

    it "labels creates, updates and destroys by table" do
      Grant::Logs.verbose_query_logs = true

      widget = VlWidget.new(label: "a")
      labels = sql_messages do
        widget.save!
        widget.update!(label: "b")
        widget.destroy
      end.select(&.includes?("↳")).map { |message| message.split(" (").first }

      labels.should eq(["vl_widgets Create", "vl_widgets Update", "vl_widgets Destroy"])
    end

    it "captures no source location below the debug level" do
      Grant::Logs.verbose_query_logs = true

      messages = sql_messages(Log::Severity::Info) { VlWidget.all.to_a }

      messages.should be_empty
    end

    it "marks a read served from the query cache" do
      Grant::Logs.verbose_query_logs = true

      messages = sql_messages do
        Grant::QueryCache.cache do
          VlWidget.all.to_a
          VlWidget.all.to_a
        end
      end

      messages.count(&.starts_with?("CACHE ")).should eq(1)
      messages.find!(&.starts_with?("CACHE ")).should eq("CACHE VlWidget Load (0.0ms)")
    end
  end

  describe ".source_location" do
    it "returns the first frame outside Grant, the standard library and lib/" do
      frames = [
        "#{Grant::Logs::GRANT_SOURCE_ROOT}/grant/base.cr:10:5 in 'find'",
        "#{Grant::Logs::GRANT_SOURCE_ROOT}/adapter/base.cr:3:1 in 'log'",
        "/opt/crystal/share/crystal/src/array.cr:99:3 in 'each'",
        "/app/lib/db/src/db.cr:1:1 in 'query'",
        "/app/src/users_controller.cr:12:5 in 'index'",
        "/app/src/main.cr:1:1 in 'main'",
      ]

      Grant::Logs.source_location(frames).should eq("/app/src/users_controller.cr:12:5 in 'index'")
    end

    it "returns nil when every frame is internal" do
      Grant::Logs.source_location(["#{Grant::Logs::GRANT_SOURCE_ROOT}/grant/base.cr:10:5 in 'find'"]).should be_nil
    end
  end

  describe ".query_label" do
    it "names a statement by table and kind" do
      Grant::Logs.query_label(%(SELECT "users"."id" FROM "users" WHERE id = 1)).should eq("users Load")
      Grant::Logs.query_label(%(SELECT EXISTS(SELECT 1 FROM users WHERE id = 1))).should eq("users Exists?")
      Grant::Logs.query_label(%(INSERT INTO `users` (a) VALUES (1))).should eq("users Create")
      Grant::Logs.query_label(%(UPDATE "users" SET a = 1)).should eq("users Update")
      Grant::Logs.query_label(%(DELETE FROM "users" WHERE id = 1)).should eq("users Destroy")
      Grant::Logs.query_label(%(SELECT id FROM users), "User").should eq("User Load")
      Grant::Logs.query_label("PRAGMA foreign_keys").should eq("SQL")
    end
  end
end
