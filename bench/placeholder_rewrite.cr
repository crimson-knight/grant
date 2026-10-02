# Compares the single-pass placeholder scanner with the per-placeholder
# String#sub rewrite it replaced, and checks they agree on plain fragments.
#
#   crystal-alpha run --release bench/placeholder_rewrite.cr
require "../src/grant"
require "../src/adapter/pg"

def legacy_numbered(clause : String, starting_index : Int32 = 0) : String
  if clause.includes?("?")
    clause.count("?").times do |i|
      clause = clause.sub("?", "$#{starting_index + i + 1}")
    end
  end
  clause
end

FRAGMENTS = {
  "1 placeholder"   => "id = ?",
  "5 placeholders"  => "a = ? AND b = ? AND c = ? AND d = ? AND e = ?",
  "20 placeholders" => (1..20).map { |i| "col_#{i} = ?" }.join(" AND "),
  "no placeholders" => "SELECT * FROM users WHERE id = $1",
}

adapter = Grant::Adapter::Pg.new(name: "bench", url: "postgres://localhost/unused")
iterations = 200_000

FRAGMENTS.each do |label, clause|
  raise "scanner and legacy output differ for #{label}" unless adapter.ensure_clause_template(clause) == legacy_numbered(clause)

  legacy = Time.measure { iterations.times { legacy_numbered(clause) } }
  scanner = Time.measure { iterations.times { adapter.ensure_clause_template(clause) } }
  printf("%-16s legacy %7.1f ns/op   scanner %7.1f ns/op   %.2fx\n",
    label, legacy.total_nanoseconds / iterations, scanner.total_nanoseconds / iterations,
    legacy.total_nanoseconds / scanner.total_nanoseconds)
end
