require "../../support/m04_tasks_fixture"
require "../../support/statement_recorder"

private def m04_truncate_world(tasks : Grant::Tasks::Database, parents : Int32 = 3) : Nil
  tasks.create
  tasks.migrate
  tasks.adapter.open { |db| db.exec "CREATE TABLE m04_keep_me (id INTEGER PRIMARY KEY, label VARCHAR(20))" }
  parents.times do |number|
    tasks.adapter.open { |db| db.exec "INSERT INTO m04_task_widgets (title) VALUES ('widget #{number}')" }
  end
  tasks.adapter.open { |db| db.exec "INSERT INTO m04_task_gadgets (widget_id) SELECT id FROM m04_task_widgets" }
  tasks.adapter.open { |db| db.exec "INSERT INTO m04_keep_me (id, label) VALUES (1, 'kept')" }
end

private def m04_task_options
  {migrations: M04_TASK_MIGRATIONS, db_dir: "db_m04"}
end

describe "Grant::Tasks::Database#truncate_all" do
  it "empties every table, keeps the migration bookkeeping and returns the tables it emptied" do
    M04Tasks.with_tasks(**m04_task_options) do |tasks|
      m04_truncate_world(tasks)
      M04Tasks.count(tasks, "m04_task_gadgets").should eq 3

      emptied = tasks.truncate_all
      emptied.sort.should eq ["m04_keep_me", "m04_task_gadgets", "m04_task_widgets"]
      M04Tasks.count(tasks, "m04_task_widgets").should eq 0
      M04Tasks.count(tasks, "m04_task_gadgets").should eq 0
      M04Tasks.count(tasks, "m04_keep_me").should eq 0
      M04Tasks.count(tasks, "schema_migrations").should eq 3
      tasks.version.should eq 20260101000003_i64
      Grant::Schema::InternalMetadata.new(tasks.adapter).environment.should eq "development"
    end
  end

  it "restarts the id counters" do
    M04Tasks.with_tasks(**m04_task_options) do |tasks|
      m04_truncate_world(tasks)
      tasks.truncate_all
      tasks.adapter.open { |db| db.exec "INSERT INTO m04_task_widgets (title) VALUES ('fresh')" }
      tasks.adapter.open { |db| db.scalar("SELECT id FROM m04_task_widgets").as(Int).to_i64 }.should eq 1
    end
  end

  it "keeps the tables named in except" do
    M04Tasks.with_tasks(**m04_task_options) do |tasks|
      m04_truncate_world(tasks)
      emptied = tasks.truncate_all(except: ["m04_keep_me"])
      emptied.should_not contain("m04_keep_me")
      M04Tasks.count(tasks, "m04_keep_me").should eq 1
      M04Tasks.count(tasks, "m04_task_widgets").should eq 0
    end
  end

  it "empties referenced tables whatever their order, without a per-table round trip on PostgreSQL" do
    M04Tasks.with_tasks(**m04_task_options) do |tasks|
      m04_truncate_world(tasks)
      statements = StatementRecorder.statements { tasks.truncate_all }
      truncates = StatementRecorder.count(statements, "TRUNCATE")
      if CURRENT_ADAPTER == "pg"
        truncates.should eq 1
        StatementRecorder.count(statements, "DELETE").should eq 0
        statements.find { |sql| sql.lstrip.upcase.starts_with?("TRUNCATE") }.not_nil!.should contain("RESTART IDENTITY CASCADE")
      end
      M04Tasks.count(tasks, "m04_task_gadgets").should eq 0
    end
  end

  it "refuses a protected environment unless forced" do
    M04Tasks.with_tasks("production", **m04_task_options) do |tasks|
      tasks.create
      tasks.adapter.open { |db| db.exec "CREATE TABLE m04_prod_rows (id INTEGER)" }
      tasks.adapter.open { |db| db.exec "INSERT INTO m04_prod_rows (id) VALUES (1)" }
      expect_raises(Grant::Schema::ProtectedEnvironmentError) { tasks.truncate_all }
      M04Tasks.count(tasks, "m04_prod_rows").should eq 1
      tasks.truncate_all(force: true).should contain("m04_prod_rows")
      M04Tasks.count(tasks, "m04_prod_rows").should eq 0
    end
  end

  it "does nothing on a database without tables" do
    M04Tasks.with_tasks(**m04_task_options) do |tasks|
      tasks.create
      tasks.truncate_all.should be_empty
    end
  end
end
