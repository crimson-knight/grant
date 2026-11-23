# Prints every table (and, unless --tables-only, every index) of a SQLite
# database as canonical JSON lines, read by Grant's pure-Crystal engine. The
# differential specs compare this output with what C SQLite returns for the
# same file (spec/grant/sqlite_engine/fixtures/generate.rb).
#
#   crystal-alpha run scripts/sqlite_engine_dump.cr -- path/to/file.db [--tables-only] [--summary]
#
# --summary also prints the header fields, the freelist and the pointer map
# to standard error.
require "../src/grant/sqlite_engine"

paths = ARGV.reject(&.starts_with?("--"))
if paths.size != 1
  STDERR.puts "usage: sqlite_engine_dump <database> [--tables-only] [--summary]"
  exit 2
end

begin
  database = Grant::SQLiteEngine::Database.open(paths.first)
  Grant::SQLiteEngine::Dump.new(database, include_indexes: !ARGV.includes?("--tables-only")).write(STDOUT)
  if ARGV.includes?("--summary")
    if header = database.header
      STDERR.puts "page_size=#{header.page_size} pages=#{database.page_count} encoding=#{header.text_encoding} " \
                  "schema_format=#{header.schema_format} auto_vacuum=#{header.has_pointer_map_pages?} " \
                  "wal_frames=#{database.pager.wal.try(&.committed_frame_count) || 0}"
    end
    freelist = database.freelist
    STDERR.puts "freelist trunks=#{freelist.list_of_trunk_pages.size} leaves=#{freelist.list_of_leaf_pages.size}"
    STDERR.puts "pointer_map entries=#{database.pointer_map_entries.size}"
  end
  database.close
rescue error : Grant::SQLiteEngine::Error
  STDERR.puts "#{error.class}: #{error.message}"
  exit 1
end
