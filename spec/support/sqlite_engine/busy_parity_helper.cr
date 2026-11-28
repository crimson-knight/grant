# A helper process of spec/grant/sqlite_engine/busy_parity_spec.cr: one or
# more connections to one database, through Grant's engine or C SQLite,
# each driven by a fiber in its own isolated execution context (its own
# thread). The spec writes one step per line on standard input and reads
# one answer per step on standard output, so every step finishes (or, for
# a step the spec starts and finishes later, is under way) before the next
# one begins.
#
#   busy_parity_helper ENGINE PATH NAMES
#
# ENGINE: grant or libsqlite3. NAMES: the connections this process opens,
# one letter each ("AB" opens A and B side by side; "A" opens A alone).
# A step is "<name> <one SQL statement>"; its answer is the tab-separated
# fields "<name> <code> <extended code> <milliseconds> <message> <rows>",
# where the message is empty on success and the rows are the statement's
# rows, columns joined by "," and rows by ";".
require "../../../src/grant/drivers/sqlite3/sqlite3/type"
require "../../../src/grant/drivers/sqlite3/sqlite3/flags"
require "../../../src/grant/drivers/sqlite3/sqlite3/engine"
require "../../../src/grant/drivers/sqlite3/grant_engine"
require "../../../src/grant/drivers/sqlite3/libsqlite3"

module BusyParityHelper
  alias Engine = Grant::SQLite3::Engine

  # One connection and the thread that runs its steps.
  class ConnectionWorker
    getter list_of_steps = Channel(String).new
    getter context : Fiber::ExecutionContext::Isolated

    def initialize(name : Char, engine : Engine, path : String, answers : Channel(String))
      @context = Fiber::ExecutionContext::Isolated.new("connection #{name}") do
        code, database = engine.open(path)
        if code == Engine::OK_CODE
          while sql = @list_of_steps.receive?
            answers.send("#{name}\t#{BusyParityHelper.run_step(database, sql)}")
          end
          database.close
        else
          answers.send("#{name}\t#{code}\t#{database.extended_error_code}\t0\topen: #{database.error_message}\t")
        end
      end
    end
  end

  # Runs the one statement *sql* to its end. Returns the answer fields
  # after the connection name.
  def self.run_step(database : Engine::Database, sql : String) : String
    list_of_rows = [] of String
    code = Engine::OK_CODE
    elapsed = Time.measure do
      code, statement = database.prepare(sql)
      if code == Engine::OK_CODE
        loop do
          step_code = statement.step
          if step_code == Engine::ROW_CODE
            list_of_rows << (0...statement.column_count).join(",") { |column| statement.column_text(column) }
          else
            code = step_code == Engine::DONE_CODE ? Engine::OK_CODE : step_code
            break
          end
        end
      end
      statement.finalize_statement
    end
    message = code == Engine::OK_CODE ? "" : database.error_message
    extended_code = code == Engine::OK_CODE ? Engine::OK_CODE : database.extended_error_code
    "#{code}\t#{extended_code}\t#{elapsed.total_milliseconds.to_i}\t#{message}\t#{list_of_rows.join(";")}"
  end

  def self.perform(engine_name : String, path : String, names : String) : Nil
    answers = Channel(String).new
    list_of_workers = names.chars.to_h do |name|
      engine = engine_name == "grant" ? Engine::GrantEngine.new : Engine::LibSQLite3Engine.new
      {name, ConnectionWorker.new(name, engine, path, answers)}
    end
    printer = Fiber::ExecutionContext::Isolated.new("answers") do
      while answer = answers.receive?
        STDOUT.puts answer
        STDOUT.flush
      end
    end
    while line = STDIN.gets
      step_worker = list_of_workers[line[0]]? || abort("no connection named #{line[0]}")
      step_worker.list_of_steps.send(line[2..])
    end
    list_of_workers.each_value do |worker|
      worker.list_of_steps.close
      worker.context.wait
    end
    answers.close
    printer.wait
  end
end

BusyParityHelper.perform(ARGV[0], ARGV[1], ARGV[2])
