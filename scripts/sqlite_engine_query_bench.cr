# Times SELECT statements on Grant's SQLite engine against C SQLite, on one
# database file C builds, the two measured in alternating rounds.
#
#   crystal-alpha build --release scripts/sqlite_engine_query_bench.cr -o bench \
#     --link-flags "-L DIR -Wl,-rpath,DIR"
#   ./bench ROWS ROUNDS REPORT_DIR [LABELS]
#
# LABELS, when given, is a comma-separated list of workload labels to run
# (e.g. "count(*) full table,prepare + find by primary key"), for profiling
# one row at a time; without it every workload runs.
#
# Each workload runs a prepared statement many times with new parameters
# (reset, bind, step to the end, reading every column), as Grant's driver
# does with its statement cache; "prepare" workloads compile the statement
# each time as well. Both engines' rows feed a checksum that must agree.
# Prints the median per-run time of each engine and the
# ratio, reported as "N× as fast" or "N× slower".
require "../spec/support/sqlite_engine/query_oracle"

private alias Value = Grant::SQLiteEngine::Value
private alias C = SQLiteSQLOracle::LibOracle
private alias Q = SQLiteQueryOracle::LibQueryOracle

record Workload, label : String, sql : String, runs : Int32, prepare_each_time : Bool,
  parameters : Proc(Int32, Array(Value))

module QueryBench
  def self.c_run(handle : C::Database, statement : C::Statement, parameters : Array(Value)) : Int64
    Q.reset(statement)
    parameters.each_with_index do |value, index|
      position = index + 1
      case value
      when Nil     then Q.bind_null(statement, position)
      when Int64   then Q.bind_int64(statement, position, value)
      when Float64 then Q.bind_double(statement, position, value)
      when String  then Q.bind_text(statement, position, value, value.bytesize, SQLiteQueryOracle::TRANSIENT)
      when Bytes   then Q.bind_blob(statement, position, value.to_unsafe.as(Void*), value.size, SQLiteQueryOracle::TRANSIENT)
      end
    end
    columns = C.column_count(statement)
    checksum = 0_i64
    while C.step(statement) == SQLiteQueryOracle::ROW
      columns.times do |column|
        case Q.column_type(statement, column)
        when 1 then checksum &+= Q.column_int64(statement, column)
        when 2 then checksum &+= Q.column_double(statement, column).to_i64!
        when 3 then checksum &+= Q.column_bytes(statement, column) + C.column_text(statement, column).value
        end
      end
    end
    checksum
  end

  def self.engine_run(query : Grant::SQLiteEngine::Query::PreparedQuery, parameters : Array(Value)) : Int64
    query.reset
    parameters.each_with_index { |value, index| query.bind(index + 1, value) }
    checksum = 0_i64
    while query.step
      query.row.each do |value|
        case value
        when Int64   then checksum &+= value
        when Float64 then checksum &+= value.to_i64!
        when String  then checksum &+= value.bytesize + (value.to_slice[0]? || 0_u8)
        end
      end
    end
    checksum
  end
end

rows = ARGV[0].to_i
rounds = ARGV[1].to_i
directory = ARGV[2]
list_of_labels = ARGV[3]?.try(&.split(",").map(&.strip))
path = File.join(Dir.tempdir, "grant-query-bench-#{Process.pid}.db")
connection = SQLiteQueryOracle::Connection.new(path)
connection.exec <<-SQL
  CREATE TABLE users (id INTEGER PRIMARY KEY, email VARCHAR(255) NOT NULL, name TEXT, age INTEGER, score REAL,
    created_at DATETIME, updated_at DATETIME);
  CREATE UNIQUE INDEX index_users_on_email ON users (email);
  CREATE INDEX index_users_on_age ON users (age);
  CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER, title VARCHAR(100), body TEXT, published BOOLEAN,
    created_at DATETIME);
  CREATE INDEX index_posts_on_user_id ON posts (user_id);
  SQL
connection.exec("BEGIN")
random = Random.new(20261123)
rows.times do |index|
  connection.query("INSERT INTO users VALUES (?, ?, ?, ?, ?, ?, ?)", [
    (index + 1).to_i64, "user#{index}@example.com", "User #{index}", random.rand(18..90).to_i64,
    random.rand * 100, "2026-11-#{(index % 28 + 1).to_s.rjust(2, '0')} 10:00:00.000000", "2026-11-23 10:00:00.000000",
  ] of Value)
  3.times do |post|
    connection.query("INSERT INTO posts (user_id, title, body, published, created_at) VALUES (?, ?, ?, ?, ?)", [
      (index + 1).to_i64, "Post #{post} of #{index}", "Body text " * 8, random.rand(2).to_i64,
      "2026-11-#{(post % 28 + 1).to_s.rjust(2, '0')} 09:00:00.000000",
    ] of Value)
  end
end
connection.exec("COMMIT")

workloads = [
  Workload.new("find by primary key", "SELECT users.id, users.email, users.name, users.age, users.score, users.created_at, users.updated_at FROM users WHERE users.id = ? LIMIT 1", 20_000, false,
    ->(run : Int32) { [(run % rows + 1).to_i64] of Value }),
  Workload.new("find by unique index", "SELECT users.id, users.email, users.name FROM users WHERE users.email = ? LIMIT 1", 20_000, false,
    ->(run : Int32) { ["user#{run % rows}@example.com"] of Value }),
  Workload.new("has_many through index", "SELECT posts.id, posts.user_id, posts.title, posts.published, posts.created_at FROM posts WHERE posts.user_id = ? ORDER BY posts.id", 10_000, false,
    ->(run : Int32) { [(run % rows + 1).to_i64] of Value }),
  Workload.new("indexed range, ordered page", "SELECT users.id, users.name FROM users WHERE users.age BETWEEN ? AND ? ORDER BY users.id LIMIT 25", 2_000, false,
    ->(run : Int32) { [(18 + run % 60).to_i64, (20 + run % 60).to_i64] of Value }),
  Workload.new("count(*) full table", "SELECT COUNT(*) FROM posts", 200, false, ->(_run : Int32) { [] of Value }),
  Workload.new("filtered scan", "SELECT users.id FROM users WHERE users.score > ? AND users.name LIKE ?", 200, false,
    ->(run : Int32) { [(run % 90).to_f64, "User 1%"] of Value }),
  Workload.new("join with aggregate", "SELECT users.id, COUNT(posts.id) FROM users INNER JOIN posts ON posts.user_id = users.id WHERE users.age > ? GROUP BY users.id ORDER BY users.id LIMIT 50", 200, false,
    ->(run : Int32) { [(80 + run % 5).to_i64] of Value }),
  Workload.new("exists subquery", "SELECT EXISTS(SELECT 1 FROM users WHERE users.email = ? LIMIT 1)", 20_000, false,
    ->(run : Int32) { ["user#{run % rows}@example.com"] of Value }),
  Workload.new("prepare + find by primary key", "SELECT users.id, users.email, users.name FROM users WHERE users.id = ? LIMIT 1", 20_000, true,
    ->(run : Int32) { [(run % rows + 1).to_i64] of Value }),
]

workloads.select! { |workload| list_of_labels.includes?(workload.label) } if list_of_labels
abort "no workload matches " if workloads.empty?

session = Grant::SQLiteEngine::Query::Session.new(Grant::SQLiteEngine::Database.open(path))
lines = [] of String
lines << "rows #{rows} users, #{rows * 3} posts; #{rounds} rounds, alternating C and engine; median per run"
lines << "C SQLite #{SQLiteSQLOracle.version}"
lines << "| Workload | C (us) | Grant engine (us) | Grant engine against C |"
lines << "|---|---|---|---|"
workloads.each do |workload|
  c_times = [] of Float64
  engine_times = [] of Float64
  C.prepare_v2(connection.handle, workload.sql, workload.sql.bytesize, out statement, nil)
  engine_query = session.prepare(workload.sql)
  c_check = 0_i64
  engine_check = 0_i64
  rounds.times do |round|
    [true, false].rotate(round % 2).each do |c_side|
      started = Time.instant
      workload.runs.times do |run|
        parameters = workload.parameters.call(run)
        if c_side
          if workload.prepare_each_time
            C.prepare_v2(connection.handle, workload.sql, workload.sql.bytesize, out fresh, nil)
            c_check &+= QueryBench.c_run(connection.handle, fresh, parameters)
            C.finalize(fresh)
          else
            c_check &+= QueryBench.c_run(connection.handle, statement, parameters)
          end
        else
          query = workload.prepare_each_time ? session.prepare(workload.sql) : engine_query
          engine_check &+= QueryBench.engine_run(query, parameters)
        end
      end
      elapsed = (Time.instant - started).total_microseconds / workload.runs
      (c_side ? c_times : engine_times) << elapsed
    end
  end
  C.finalize(statement)
  abort "checksums differ for #{workload.label}: C #{c_check}, engine #{engine_check}" unless c_check == engine_check
  c_median = c_times.sort[c_times.size // 2]
  engine_median = engine_times.sort[engine_times.size // 2]
  ratio = engine_median <= c_median ? "#{(c_median / engine_median).round(2)}x as fast" : "#{(engine_median / c_median).round(2)}x slower"
  lines << "| #{workload.label} | #{c_median.round(2)} | #{engine_median.round(2)} | #{ratio} |"
end
connection.close
File.delete(path)
Dir.mkdir_p(directory)
File.write(File.join(directory, "query_speed.md"), lines.join("\n") + "\n")
puts lines.join("\n")
