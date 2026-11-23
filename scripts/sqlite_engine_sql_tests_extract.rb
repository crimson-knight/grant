#!/usr/bin/ruby
# Extracts the SQL that SQLite's own Tcl test suite runs, for comparing the
# engine's parser with C SQLite's on it.
#
#   /usr/bin/ruby scripts/sqlite_engine_sql_tests_extract.rb SQLITE_SRC/test OUT.jsonl
#
# Every brace-quoted block passed to execsql, catchsql, do_execsql_test,
# do_catchsql_test, do_eqp_test or `db eval` becomes one record,
# {"source": "file.test:line", "sql": "..."}. Blocks may hold several
# statements; the comparison splits them with sqlite3_complete. Blocks in
# double quotes are skipped, since Tcl substitutes variables into them.
require "json"

test_directory = ARGV[0] or abort "usage: sqlite_engine_sql_tests_extract.rb TEST_DIR OUT.jsonl"
output_path = ARGV[1] or abort "missing OUT.jsonl"

COMMANDS = /(?:\b(execsql|catchsql|do_execsql_test|do_catchsql_test|do_eqp_test)\b|\bdb2? eval\b)/

# Reads the brace-balanced block whose opening brace is at *start*.
def brace_block(text, start)
  depth = 0
  index = start
  while index < text.size
    char = text[index]
    if char == "\\"
      index += 2
      next
    end
    depth += 1 if char == "{"
    depth -= 1 if char == "}"
    return [text[(start + 1)...index], index] if depth.zero?
    index += 1
  end
  nil
end

# Skips Tcl words (a test name, -db options) before the SQL block.
def skip_words(text, index, count)
  count.times do
    index += 1 while index < text.size && text[index] =~ /[ \t]/
    return index if text[index] == "{" || text[index] == "\n"
    index += 1 while index < text.size && text[index] !~ /[\s{]/
  end
  index += 1 while index < text.size && text[index] =~ /[ \t]/
  index
end

records = 0
files = 0
File.open(output_path, "w") do |output|
  Dir.glob(File.join(test_directory, "*.test")).sort.each do |path|
    files += 1
    text = File.binread(path).force_encoding("UTF-8").scrub("?")
    name = File.basename(path)
    position = 0
    while (match = COMMANDS.match(text, position))
      position = match.end(0)
      command = match[1]
      index = position
      if command && command.start_with?("do_")
        index = skip_words(text, index, command == "do_eqp_test" ? 1 : 3)
      else
        index += 1 while index < text.size && text[index] =~ /[ \t]/
        index = skip_words(text, index, 2) if text[index] == "-"
      end
      next unless text[index] == "{"
      block = brace_block(text, index)
      next unless block
      sql, finish = block
      next if sql.strip.empty?
      line = text[0...index].count("\n") + 1
      output.puts({ "source" => "#{name}:#{line}", "sql" => sql }.to_json)
      records += 1
      position = finish
    end
  end
end
STDERR.puts "#{files} test files, #{records} SQL blocks"
