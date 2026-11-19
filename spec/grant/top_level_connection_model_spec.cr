require "../spec_helper"
require "log/spec"

# Issues #63 and #72: an app model named `Connection` shares its name with
# `Grant::Connection`. Every place Grant pastes a model type into code that sits
# inside the `Grant` namespace (the log table map, the polymorphic and STI
# dispatch tables, the preloader, array conditions) must reach
# the app's top-level model. This file compiling at all is the first half of
# the proof; the specs below prove each of those paths also runs.
#
# One program holds only one top-level `Connection`, so this one model is the
# STI root, a polymorphic target, and the logged model at once.
{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class Connection < Grant::Base
    include Grant::STI
    connection {{ adapter_literal }}
    table top_level_connections

    column id : Int64, primary: true
    column type : String
    column host_address : String

    has_many :notes, as: :notable, class_name: "ConnectionNote"

    # Hand-written registrations with an unrooted path replace the automatic
    # ones; the registries must still store the app's class.
    Grant::Polymorphic.register_polymorphic_type("Connection", Connection)
    Grant::STI.register_sti_type("Connection", Connection)
  end

  class PooledConnection < Connection
  end

  class ConnectionNote < Grant::Base
    connection {{ adapter_literal }}
    table top_level_connection_notes

    column id : Int64, primary: true
    column body : String

    belongs_to :notable, polymorphic: true, optional: true
  end

  # Issue #74: a `class_name:` naming the top-level model must not resolve to
  # `Grant::Connection` when Grant reads the association.
  class ConnectionProbe < Grant::Base
    connection {{ adapter_literal }}
    table top_level_connection_probes

    column id : Int64, primary: true
    column status_label : String

    belongs_to :upstream, class_name: Connection
  end
{% end %}

private def top_level_connection_sql_messages(& : ->) : Array(String)
  backend = Log::MemoryBackend.new
  Log.builder.bind("grant.sql", Log::Severity::Debug, backend)
  begin
    yield
  ensure
    Log.builder.unbind("grant.sql", Log::Severity::Debug, backend)
  end
  backend.entries.compact_map(&.message)
end

describe "A top-level model named Connection" do
  before_all do
    ::Connection.migrator.drop_and_create
    ::ConnectionNote.migrator.drop_and_create
    ::ConnectionProbe.migrator.drop_and_create
  end

  before_each do
    ::ConnectionProbe.clear
    ::ConnectionNote.clear
    ::Connection.clear
  end

  describe "query logs" do
    before_each do
      Grant::Logs.verbose_query_logs = true
    end

    after_each do
      Grant::Logs.verbose_query_logs = false
    end

    it "maps its table to the top-level model, not Grant::Connection" do
      Grant::Logs.model_name_for_table("top_level_connections").should eq("Connection")
    end

    it "saves and labels its verbose query logs with the model name" do
      record = ::Connection.new(host_address: "db.example.test")
      messages = top_level_connection_sql_messages { record.save! }

      record.persisted?.should be_true
      labels = messages.select(&.includes?("↳")).map(&.split(" (").first)
      labels.should eq(["Connection Create"])
    end
  end

  describe "single-table inheritance" do
    it "resolves the stored type names to the top-level classes" do
      ::Connection.find_sti_class("Connection").should eq(::Connection)
      ::Connection.find_sti_class("PooledConnection").should eq(::PooledConnection)
    end

    it "loads a subclass row through the root as the subclass" do
      pooled = ::PooledConnection.new(host_address: "pool.example.test")
      pooled.save!

      loaded = ::Connection.find!(pooled.id)
      loaded.should be_a(::PooledConnection)
      loaded.host_address.should eq("pool.example.test")
    end

    it "converts a record to a sibling class with becomes" do
      root = ::Connection.new(host_address: "db.example.test")
      pooled = root.becomes(::PooledConnection)

      pooled.read_attribute("type").should eq("PooledConnection")
      pooled.host_address.should eq("db.example.test")
    end
  end

  describe "polymorphic associations" do
    it "loads the top-level model from its stored type name" do
      target = ::Connection.new(host_address: "db.example.test")
      target.save!

      loaded = Grant::Polymorphic.load_polymorphic("Connection", target.id)
      loaded.should be_a(::Connection)
    end

    it "reads a note's notable back as the top-level model" do
      target = ::Connection.new(host_address: "db.example.test")
      target.save!
      note = ::ConnectionNote.new(body: "primary")
      note.notable = target
      note.save!

      reloaded = ::ConnectionNote.find!(note.id)
      reloaded.notable_type.should eq("Connection")
      reloaded.notable.should be_a(::Connection)
    end

    it "eager-loads polymorphic targets of the top-level model" do
      target = ::Connection.new(host_address: "db.example.test")
      target.save!
      note = ::ConnectionNote.new(body: "primary")
      note.notable = target
      note.save!

      notes = ::ConnectionNote.includes(:notable).to_a
      notes.first.notable.should be_a(::Connection)
    end
  end

  describe "eager loading through class_name:" do
    it "eager-loads a belongs_to whose class_name: is the top-level model" do
      target = ::Connection.new(host_address: "db.example.test")
      target.save!
      ::ConnectionProbe.create!(status_label: "up", upstream_id: target.id)

      probes = ::ConnectionProbe.includes(:upstream).to_a
      probes.first.upstream.should be_a(::Connection)
    end
  end

  describe "preloading" do
    it "preloads an association on records of the top-level model" do
      target = ::Connection.new(host_address: "db.example.test")
      target.save!
      ::ConnectionNote.create!(body: "primary", notable_id: target.id, notable_type: "Connection")

      records = ::Connection.all.to_a
      Grant::Preloader.new(records, :notes).call

      records.first.notes.to_a.map(&.body).should eq(["primary"])
    end
  end

  describe "array conditions" do
    it "rejects a union of record arrays under a column instead of dropping the condition" do
      target = ::Connection.new(host_address: "db.example.test")
      values = ENV["GRANT_NEVER_SET_FOR_THIS_SPEC"]? ? [1_i64] : [target]

      expect_raises(ArgumentError, /not an association/) do
        ::ConnectionNote.where(body: values).to_a
      end
    end
  end
end
