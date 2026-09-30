require "../spec_helper"
require "../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class QlWidget < Grant::Base
    connection {{ adapter_literal }}
    table ql_widgets

    column id : Int64, primary: true
    column label : String
  end
{% end %}

private def widget_statements(verb : String, & : ->) : Array(String)
  statements = StatementRecorder.statements { yield }
  statements.select { |sql| sql.lstrip.upcase.starts_with?(verb) && sql.includes?("ql_widgets") }
end

describe Grant::QueryLogs do
  before_all do
    QlWidget.migrator.drop_and_create
  end

  before_each do
    QlWidget.clear
    Grant::QueryLogs.reset!
  end

  after_each do
    Grant::QueryLogs.reset!
  end

  describe "while disabled" do
    it "leaves the SQL untouched even with tags configured" do
      Grant::QueryLogs.tag(:application, "shop")

      Grant::QueryLogs.append("SELECT 1").should eq("SELECT 1")
      widget_statements("SELECT") { QlWidget.all.to_a }.each { |sql| sql.should_not contain("/*") }
    end
  end

  describe "legacy format" do
    it "appends the tags as a trailing comment, never a leading one" do
      Grant::QueryLogs.enabled = true
      Grant::QueryLogs.tag(:application, "shop")

      selects = widget_statements("SELECT") { QlWidget.where(label: "x").to_a }

      selects.size.should eq(1)
      selects.first.should end_with("/*application:shop*/")
      selects.first.should start_with("SELECT")
    end

    it "writes the tags in declaration order, then the fiber context" do
      Grant::QueryLogs.enabled = true
      Grant::QueryLogs.tag(:application, "shop")
      Grant::QueryLogs.tag(:region, "eu")

      Grant::QueryLogs.with_context(controller: "users", action: "index") do
        Grant::QueryLogs.comment.should eq("/*application:shop,region:eu,controller:users,action:index*/")
      end
    end

    it "evaluates a block tag for every statement and skips a nil value" do
      Grant::QueryLogs.enabled = true
      counter = 0
      Grant::QueryLogs.tag(:request_id) { "req-#{counter += 1}" }
      Grant::QueryLogs.tag(:user) { nil }

      Grant::QueryLogs.comment.should eq("/*request_id:req-1*/")
      Grant::QueryLogs.comment.should eq("/*request_id:req-2*/")
    end

    it "replaces an earlier tag of the same name" do
      Grant::QueryLogs.enabled = true
      Grant::QueryLogs.tag(:application, "old")
      Grant::QueryLogs.tag(:application, "new")

      Grant::QueryLogs.comment.should eq("/*application:new*/")
    end

    it "adds no comment when no tag has a value" do
      Grant::QueryLogs.enabled = true

      Grant::QueryLogs.comment.should be_nil
      Grant::QueryLogs.append("SELECT 1").should eq("SELECT 1")
    end
  end

  describe "comment escaping" do
    it "neutralizes */ in a value so it cannot end the comment" do
      Grant::QueryLogs.enabled = true

      Grant::QueryLogs.with_context(action: "x*/; DROP TABLE ql_widgets; --") do
        comment = Grant::QueryLogs.comment.not_nil!
        comment.should eq("/*action:x* /; DROP TABLE ql_widgets; --*/")
        comment.index("*/").should eq(comment.size - 2)
      end
    end

    it "neutralizes /* so MySQL cannot run an executable comment" do
      Grant::QueryLogs.enabled = true

      Grant::QueryLogs.with_context(action: "/*!50000 DROP */") do
        comment = Grant::QueryLogs.comment.not_nil!
        comment.index("/*", 2).should be_nil
        comment.scan("*/").size.should eq(1)
        comment.should end_with(" */")
      end
    end

    it "keeps an escaped value out of the statement the database receives" do
      Grant::QueryLogs.enabled = true

      Grant::QueryLogs.with_context(action: "x*/ SELECT 2 /*") do
        selects = widget_statements("SELECT") { QlWidget.all.to_a }
        selects.first.scan("*/").size.should eq(1)
        selects.first.should end_with("*/")
      end
    end
  end

  describe "sqlcommenter format" do
    it "sorts the keys and single-quotes URL-encoded values" do
      Grant::QueryLogs.enabled = true
      Grant::QueryLogs.format = Grant::QueryLogs::Format::SQLCommenter
      Grant::QueryLogs.tag(:application, "my app")

      Grant::QueryLogs.with_context(controller: "users", action: "it's/index") do
        Grant::QueryLogs.comment.should eq("/*action='it%27s%2Findex',application='my%20app',controller='users'*/")
      end
    end

    it "is appended to the executed statement" do
      Grant::QueryLogs.enabled = true
      Grant::QueryLogs.format = Grant::QueryLogs::Format::SQLCommenter

      statements = Grant::QueryLogs.with_context(route: "/widgets") do
        widget_statements("SELECT") { QlWidget.all.to_a }
      end

      statements.first.should end_with("/*route='%2Fwidgets'*/")
    end
  end

  describe "fiber-local context" do
    it "merges nested contexts and restores the outer one" do
      Grant::QueryLogs.with_context(controller: "users") do
        Grant::QueryLogs.with_context(action: "show", controller: "admin/users") do
          Grant::QueryLogs.context.should eq({"controller" => "admin/users", "action" => "show"})
        end
        Grant::QueryLogs.context.should eq({"controller" => "users"})
      end
      Grant::QueryLogs.context.should be_empty
    end

    it "restores the context when the block raises" do
      expect_raises(Exception, "boom") do
        Grant::QueryLogs.with_context(job: "Digest") { raise "boom" }
      end
      Grant::QueryLogs.context.should be_empty
    end

    it "does not leak between fibers" do
      Grant::QueryLogs.enabled = true
      seen = Channel(String?).new

      Grant::QueryLogs.with_context(controller: "outer") do
        spawn { seen.send(Grant::QueryLogs.comment) }
        seen.receive.should be_nil
        Grant::QueryLogs.comment.should eq("/*controller:outer*/")
      end

      done = Channel(String?).new
      spawn do
        Grant::QueryLogs.with_context(job: "a") do
          Fiber.yield
          done.send(Grant::QueryLogs.comment)
        end
      end
      spawn do
        Grant::QueryLogs.with_context(job: "b") do
          Fiber.yield
          done.send(Grant::QueryLogs.comment)
        end
      end
      [done.receive, done.receive].compact.sort.should eq(["/*job:a*/", "/*job:b*/"])
    end

    it "tags the statements issued inside the block only" do
      Grant::QueryLogs.enabled = true

      inside = Grant::QueryLogs.with_context(controller: "widgets") do
        widget_statements("SELECT") { QlWidget.all.to_a }
      end
      outside = widget_statements("SELECT") { QlWidget.all.to_a }

      inside.first.should end_with("/*controller:widgets*/")
      outside.first.should_not contain("/*")
    end
  end

  describe "across statement kinds" do
    it "tags record inserts, updates and deletes, and relation counts and bulk writes" do
      Grant::QueryLogs.enabled = true
      Grant::QueryLogs.tag(:application, "shop")

      widget = QlWidget.new(label: "a")
      inserts = widget_statements("INSERT") { widget.save! }
      updates = widget_statements("UPDATE") { widget.update!(label: "b") }
      bulk = widget_statements("UPDATE") { QlWidget.where(label: "b").update_all(label: "c") }
      counts = widget_statements("SELECT") { QlWidget.count }
      deletes = widget_statements("DELETE") { widget.destroy }

      [inserts, updates, bulk, counts, deletes].each do |group|
        group.size.should eq(1)
        group.first.should end_with("/*application:shop*/")
      end
    end

    it "keeps an annotate comment where it is and adds the tags after the SQL" do
      Grant::QueryLogs.enabled = true
      Grant::QueryLogs.tag(:application, "shop")

      selects = widget_statements("/*") { QlWidget.all.annotate("dash").to_a }

      selects.first.should start_with("/* dash */ SELECT")
      selects.first.should end_with("/*application:shop*/")
    end

    it "does not tag a statement twice" do
      Grant::QueryLogs.enabled = true
      Grant::QueryLogs.tag(:application, "shop")

      once = Grant::QueryLogs.append("SELECT 1")
      Grant::QueryLogs.append(once).should eq(once)
    end
  end
end
