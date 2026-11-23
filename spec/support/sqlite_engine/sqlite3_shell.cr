# A `sqlite3` process kept open on one database, so a spec can hold a C
# SQLite transaction or read lock while the engine acts, and compare the
# lock outcomes of the two. Each `run` sends SQL and returns what sqlite3
# printed for it (output and errors) once a marker comes back.
class SQLiteEngineShell
  getter path : String
  @process : Process
  @marker = 0

  def initialize(@path : String, *, busy_timeout : Int32 = 0)
    @process = Process.new("sqlite3", [@path] of String, input: :pipe, output: :pipe, error: :pipe)
    # sqlite3 writes errors to stderr; one reader fiber copies them into
    # the output channel in order with the results.
    @lines = Channel(String).new(1_024)
    spawn { @process.output.each_line { |line| @lines.send(line) } }
    spawn { @process.error.each_line { |line| @lines.send("error: #{line}") } }
    run(".timeout #{busy_timeout}") if busy_timeout > 0
  end

  # Runs *sql* and returns the lines sqlite3 printed for it, errors
  # prefixed with "error: ".
  def run(sql : String) : Array(String)
    @marker += 1
    marker = "-- marker #{@marker} --"
    @process.input.puts(sql)
    @process.input.puts("SELECT '#{marker}';")
    @process.input.flush
    collected = [] of String
    loop do
      line = select
      when received = @lines.receive
        received
      when timeout(30.seconds)
        raise "sqlite3 did not answer #{sql.inspect}; so far: #{collected}"
      end
      break if line == marker
      collected << line
    end
    # Errors arrive on their own pipe; give a late one a moment to land.
    sleep 20.milliseconds
    while extra = (select
          when received = @lines.receive then received
          else
            nil
          end)
      collected << extra
    end
    collected
  end

  # True when the lines name SQLITE_BUSY ("database is locked").
  def self.busy?(lines : Array(String)) : Bool
    lines.any?(&.includes?("database is locked"))
  end

  def close : Nil
    @process.input.puts(".quit")
    @process.input.close
    @process.wait
  end
end
