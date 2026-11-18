require "../../spec_helper"

# Each `Grant::TextMatching` method replaces a regular expression Grant used on
# its default path. These specs run the original expression and the
# hand-written check side by side over a table of inputs (empty text, Unicode
# letters, digits and spaces, separators, case folds such as the Kelvin sign,
# and very long text) plus a seeded fuzz corpus built from the tokens each
# pattern cares about, and require identical answers.

private alias TM = Grant::TextMatching

# Characters that exercise Unicode classes and case-insensitive folding.
private UNICODE_TOKENS = ["é", "́", "K", "ſ", "٣", " ", " ", "\u0085", "᠎", "ı", "İ", "😀", "\t", "\n"]

private COMMON_INPUTS = [
  "", " ", "a", "_", "1", "?", "$", "$1", ".", ",", "'", "\"", "`", "(", ")",
  "K", "ſ", "é", "٣", " ", " ", "\n", "😀",
  "x" * 10_000, " " * 10_000, "1" * 10_000, ("a" * 5_000) + "." + ("b" * 5_000),
]

# A deterministic corpus: *count* strings built from 0 to *max_tokens* tokens.
private def fuzz_corpus(tokens : Array(String), count = 3_000, max_tokens = 12, seed = 20_261_118) : Array(String)
  random = Random.new(seed)
  all_tokens = tokens + UNICODE_TOKENS
  Array.new(count) do
    String.build do |io|
      random.rand(0..max_tokens).times { io << all_tokens.sample(random) }
    end
  end
end

private def inputs_for(tokens : Array(String), extra = [] of String) : Array(String)
  COMMON_INPUTS + extra + fuzz_corpus(tokens) + tokens
end

# Compares *old* and *new* over *inputs* and lists the inputs where they differ.
private def mismatches(inputs : Array(String), &block : String -> {T, T}) : Array(String) forall T
  inputs.compact_map do |input|
    expected, actual = block.call(input)
    expected == actual ? nil : "#{input.inspect}: expected #{expected.inspect}, got #{actual.inspect}"
  end.first(10)
end

IDENTIFIER_TOKENS = ["a", "Z", "_", "0", "9", ".", " ", "-", "users", "id", "K"]
SQL_TOKENS        = [" ", "  ", "SELECT", "select", "FROM", "from", "INTO", "UPDATE", "ONLY", "only", "users", "\"users\"", "`t`", "[t]", "public.users", "$x", "WHERE", "where", "id", "=", "?", "$1", "$12", ",", "(", ")", "'a'", "'", "1", "42", "x1", "ORDER", "BY", "by", "LIMIT", "OFFSET", "GROUP", "for", "FOR", "update", "share", "SHARE", "no", "key", "KEY", "KEY", "ſHARE", "NOT", "IN", "in", "LIKE", "ILIKE", "liKe", "!=", "<>", "<=", ">=", "<", ">", "INSERT", "VALUES", "values", "JOIN", "join", "AS", "as", "ON", "USING", "INNER", "LEFT", "posts", "p", ".", "\""]

describe Grant::TextMatching do
  it "matches bare identifiers like /\\A[A-Za-z_][A-Za-z0-9_]*\\z/" do
    mismatches(inputs_for(IDENTIFIER_TOKENS)) { |text| {text.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/), TM.simple_identifier?(text)} }.should be_empty
  end

  it "matches qualified identifiers like the old SqlExpression.identifier? pattern" do
    mismatches(inputs_for(IDENTIFIER_TOKENS)) { |text| {text.matches?(/\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?\z/), TM.qualified_identifier?(text)} }.should be_empty
  end

  it "matches lock clauses like Grant::Locking::Clause's old PATTERN" do
    tokens = ["FOR", " ", "UPDATE", "OF", "users", ",", ".", "_", "1", ";", "(", "--", "'"]
    mismatches(inputs_for(tokens)) { |text| {text.matches?(/\A[A-Za-z][A-Za-z0-9_., ]*\z/), TM.lock_clause?(text)} }.should be_empty
  end

  it "reads URL schemes like /\\A([A-Za-z][A-Za-z0-9+.\\-]*):/" do
    tokens = ["postgres", "sqlite3", "a", "1", "+", ".", "-", ":", "//", "/", "@", "?", "#", "user:pa@ss", "h"]
    mismatches(inputs_for(tokens)) { |text| {text.match(/\A([A-Za-z][A-Za-z0-9+.\-]*):/).try(&.[1]), TM.url_scheme(text)} }.should be_empty
  end

  it "redacts URL credentials like the old Registry.redact substitution" do
    tokens = ["postgres", "://", ":", "/", "user", "pa@ss", "@", "?", "#", "host", "db", "x=1", "+"]
    mismatches(inputs_for(tokens)) { |text| {text.sub(/\A([A-Za-z][A-Za-z0-9+.\-]*:\/\/)[^?#]*@/, "\\1***@"), TM.redact_url_credentials(text)} }.should be_empty
  end

  it "strips SQLite schemes like /\\Asqlite3?:(?:\\/\\/)?/" do
    tokens = ["sqlite", "sqlite3", ":", "//", "/", "3", "./db.sqlite3", "?mode=memory"]
    mismatches(inputs_for(tokens)) { |text| {text.sub(/\Asqlite3?:(?:\/\/)?/, ""), TM.strip_sqlite_scheme(text)} }.should be_empty
  end

  it "replaces PostgreSQL schemes like /\\Apostgres(ql)?:/" do
    tokens = ["postgres", "postgresql", "ql", ":", "//", "host", "x"]
    mismatches(inputs_for(tokens)) { |text| {text.sub(/\Apostgres(ql)?:/, "grant-pg:"), TM.replace_postgres_scheme(text, "grant-pg:")} }.should be_empty
  end

  it "finds encoding options like /[?&]encoding=/i" do
    tokens = ["?", "&", "encoding", "ENCODING", "=", "utf8", "x", "enco"]
    mismatches(inputs_for(tokens)) { |text| {text.matches?(/[?&]encoding=/i), TM.encoding_option?(text)} }.should be_empty
  end

  it "strips trailing sort directions like /\\s+(?:ASC|DESC)\\z/i" do
    tokens = ["name", " ", "ASC", "asc", "DESC", "desc", "deſc", "aſc", "x", "(", ")"]
    mismatches(inputs_for(tokens)) { |text| {text.sub(/\s+(?:ASC|DESC)\z/i, ""), TM.strip_trailing_sort_direction(text)} }.should be_empty
  end

  it "rewrites numbered placeholders like gsub(/\\$(\\d+)/)" do
    tokens = ["$", "1", "12", "x", " ", "?", "$1", "$$"]
    mismatches(inputs_for(tokens)) do |text|
      {text.gsub(/\$(\d+)/) { |match| "<#{match}>" }, TM.replace_numbered_placeholders(text) { |match| "<#{match}>" }}
    end.should be_empty
  end

  it "rewrites table qualifiers like gsub(/(?<![\\w.\"`])users\\./)" do
    tokens = ["users", ".", "name", "\"", "`", "x", " ", "_", "1", "(", "p_users"]
    mismatches(inputs_for(tokens)) { |text| {text.gsub(/(?<![\w."`])#{Regex.escape("users")}\./, "q."), TM.replace_table_qualifier(text, "users", "q.")} }.should be_empty
    mismatches(inputs_for(tokens + ["us.ers"])) { |text| {text.gsub(/(?<![\w."`])#{Regex.escape("us.ers")}\./, "q."), TM.replace_table_qualifier(text, "us.ers", "q.")} }.should be_empty
  end

  it "splits SQL into words like split(/([a-zA-Z0-9_$']+)/)" do
    mismatches(inputs_for(SQL_TOKENS)) { |text| {text.split(/([a-zA-Z0-9_$']+)/), TM.split_sql_words(text)} }.should be_empty
  end

  it "keeps ASCII digits like gsub(/[^0-9]/, \"\") (Builder#cache_version_string)" do
    mismatches(inputs_for(SQL_TOKENS + ["2026-11-18 10:00:00", "٣"])) { |text| {text.gsub(/[^0-9]/, ""), text.delete { |char| !char.ascii_number? }} }.should be_empty
  end

  it "finds digits like =~ /d+/" do
    mismatches(inputs_for(SQL_TOKENS)) { |text| {!(text =~ /\d+/).nil?, TM.contains_digit?(text)} }.should be_empty
  end

  it "finds statement kinds like /SELECT/i, /INSERT/i, /UPDATE/i and /DELETE/i" do
    inputs = inputs_for(SQL_TOKENS + ["DELETE", "deleKe", "ſELECT", "Inſert"])
    {"select" => /SELECT/i, "insert" => /INSERT/i, "update" => /UPDATE/i, "delete" => /DELETE/i}.each do |keyword, pattern|
      mismatches(inputs) { |text| {text.matches?(pattern), TM.contains_ignoring_case?(text, keyword)} }.should be_empty
    end
  end

  it "normalizes SQL shapes like the old N+1 detector chain" do
    tokens = SQL_TOKENS + ["12", "a12", "12a", "'x y'", "''", "$3"]
    mismatches(inputs_for(tokens)) do |text|
      old = text.gsub(/\b\d+\b/, "?").gsub(/'[^']*'/, "?").gsub(/\$\d+/, "?").gsub(/\s+/, " ")
      {old, TM.normalize_sql_shape(text)}
    end.should be_empty
  end

  it "detects locking reads like the old Grant::QueryCache::LOCKING_READ" do
    tokens = SQL_TOKENS + ["FOR UPDATE", "for share", "FOR NO KEY UPDATE", "for key share", "foR", "updated", "x"]
    mismatches(inputs_for(tokens)) { |text| {text.matches?(/\bfor\s+(update|share|no\s+key\s+update|key\s+share)\b/i), TM.locking_read?(text)} }.should be_empty
  end

  it "detects non-WHERE clause keywords like /\\b(ORDER\\s+BY|LIMIT|OFFSET|GROUP\\s+BY)\\b/i" do
    tokens = SQL_TOKENS + ["ORDER BY", "group  by", "limited", "xLIMIT", "OFFſET"]
    mismatches(inputs_for(tokens)) { |text| {text.matches?(/\b(ORDER\s+BY|LIMIT|OFFSET|GROUP\s+BY)\b/i), TM.trailing_clause_keyword?(text)} }.should be_empty
  end

  it "strips a leading WHERE like /\\AWHERE\\s+/i" do
    mismatches(inputs_for(SQL_TOKENS)) { |text| {text.sub(/\AWHERE\s+/i, ""), TM.strip_leading_where(text)} }.should be_empty
  end

  it "rewrites a leading TIMESTAMP like sub(/ATIMESTAMP((d+))?/i)" do
    tokens = ["TIMESTAMP", "timestamp", "TIMEſTAMP", "(", ")", "6", "12", " ", "WITH TIME ZONE", "x", "٣"]
    mismatches(inputs_for(tokens)) { |text| {text.sub(/\ATIMESTAMP(\(\d+\))?/i, "TIMESTAMP(3)"), TM.replace_leading_timestamp(text, "TIMESTAMP(3)")} }.should be_empty
  end

  it "recognizes MySQL literal defaults like the old Schema::MYSQL_LITERAL_DEFAULT" do
    tokens = ["'", "''", "\\", "\\'", "a", "-", "+", "1", "12", ".", "5", "\n", "٣", " "]
    mismatches(inputs_for(tokens, ["'a''b'", "'a\\'b'", "-1.5", "+3", "1.", ".5", "'\\\n'"])) { |text| {text.matches?(/\A(?:'(?:[^'\\]|''|\\.)*'|[-+]?\d+(?:\.\d+)?)\z/), TM.mysql_literal_default?(text)} }.should be_empty
  end

  it "recognizes bare time defaults like the old Dialect#default_expression patterns" do
    tokens = ["CURRENT_TIMESTAMP", "current_date", "CURRENT_TIME", "NOW", "LOCALTIMESTAMP", "LOCALTIME", "(", ")", "6", "x", " ", "CURRENT_TIMEſTAMP"]
    inputs = inputs_for(tokens)
    mismatches(inputs) { |text| {text.matches?(/\A(CURRENT_TIMESTAMP|CURRENT_DATE|CURRENT_TIME|NOW|LOCALTIMESTAMP|LOCALTIME)(\(\d*\))?\z/i), TM.bare_time_default?(text, mysql: true)} }.should be_empty
    mismatches(inputs) { |text| {text.matches?(/\ACURRENT_(TIMESTAMP|DATE|TIME)\z/i), TM.bare_time_default?(text, mysql: false)} }.should be_empty
    mismatches(inputs) { |text| {text.matches?(/\A(CURRENT_TIMESTAMP|CURRENT_TIME|NOW|LOCALTIMESTAMP|LOCALTIME)\z/i), TM.current_time_keyword?(text)} }.should be_empty
  end

  it "reads time type precision like /\\A(?:DATETIME|TIMESTAMP|TIME)\\((\\d+)\\)/i" do
    tokens = ["DATETIME", "timestamp", "TIME", "(", ")", "6", "0", "x", " ", "TIMEſTAMP"]
    mismatches(inputs_for(tokens)) { |text| {text.match(/\A(?:DATETIME|TIMESTAMP|TIME)\((\d+)\)/i).try(&.[1]), TM.time_type_precision(text)} }.should be_empty
  end

  it "drops parenthesized parts like sub(/\\(\\d+\\)/) and sub(/\\s*\\(.*\\)/)" do
    tokens = ["varchar", "(", ")", "255", "12, 2", " ", "\n", "x", "٣", "with time zone"]
    mismatches(inputs_for(tokens)) { |text| {text.sub(/\(\d+\)/, ""), TM.remove_parenthesized_number(text)} }.should be_empty
    mismatches(inputs_for(tokens)) { |text| {text.sub(/\s*\(.*\)/, ""), TM.remove_parenthesized_suffix(text)} }.should be_empty
  end

  it "finds the statement table like the old Grant::Logs::TABLE_AFTER" do
    tokens = SQL_TOKENS + ["FROM ONLY", "INSERT INTO", "K"]
    mismatches(inputs_for(tokens)) { |text| {text.match(/\b(?:FROM|INTO|UPDATE)\s+(?:ONLY\s+)?[`"\[]?([\w.$]+)/i).try(&.[1]), TM.statement_table(text)} }.should be_empty
  end

  it "recognizes frames with a line like the old Grant::Logs::FRAME_LOCATION" do
    tokens = ["src/app.cr", ":", "12", "3", " ", "in", "'method'", "??", "\n", "/x/", "٣"]
    mismatches(inputs_for(tokens)) do |text|
      old = (match = text.match(/\A(.+?:\d+(?::\d+)?)(.*)\z/m)) ? "#{match[1]}#{match[2]}" : nil
      {old, TM.frame_with_line?(text) ? text : nil}
    end.should be_empty
  end

  it "recognizes standard library paths like the old Grant::Logs::STDLIB_FRAME" do
    tokens = ["/", "share", "crystal", "agent-crystal", "src", "lib", "x", ".", "-", "_", "1.21", "HEAD", "/share/", "/src/", "/crystal/", " "]
    mismatches(inputs_for(tokens)) { |text| {text.matches?(%r{/(?:share/[\w.-]*crystal[\w.-]*|crystal)/src/}), TM.stdlib_path?(text)} }.should be_empty
  end

  it "recognizes bcrypt digests like the old SecurePassword::DIGEST_FORMAT" do
    body = "." * 22 + "abcdefghijklmnopqrstuvwxyzABCDE"
    good = "$2a$12$#{body}"
    extra = [good, "$2$12$#{body}", "$2y$١٢$#{body}", "$2c$12$#{body}", "$2a$1$#{body}", "$2a$12$#{body}x", "$2a$12$#{body[1..]}", "$2a$12$#{body}\n"]
    tokens = ["$", "2", "a", "b", "x", "y", "12", ".", "/", "A", "z"]
    mismatches(inputs_for(tokens, extra)) { |text| {text.matches?(/\A\$2[abxy]?\$\d{2}\$[.\/A-Za-z0-9]{53}\z/), TM.bcrypt_digest?(text)} }.should be_empty
  end

  it "replaces named placeholders like gsub(/%\\{(\\w+)\\}/)" do
    tokens = ["%", "{", "}", "%{", "attribute", "message", "count", "x", " ", "_"]
    mismatches(inputs_for(tokens)) do |text|
      {text.gsub(/%\{(\w+)\}/) { |whole, match| "<#{whole}|#{match[1]}>" }, TM.replace_named_placeholders(text) { |whole, name| "<#{whole}|#{name}>" }}
    end.should be_empty
  end

  it "applies the pluralizer suffix rules like /(?:s|x|z|ch|sh)\\z/ and /[^aeiou]y\\z/" do
    tokens = ["s", "x", "z", "ch", "sh", "y", "a", "e", "o", "b", "h", "Y", "\n"]
    mismatches(inputs_for(tokens)) { |text| {text.matches?(/(?:s|x|z|ch|sh)\z/), TM.plural_suffix_es?(text)} }.should be_empty
    mismatches(inputs_for(tokens)) { |text| {text.matches?(/[^aeiou]y\z/), TM.consonant_y_ending?(text)} }.should be_empty
  end

  it "finds qualifiers like the old association reference scan" do
    tokens = ["users", "\"users\"", ".", "\"", "name", " ", "=", "?", "_", "1", "x.y", "é", "AND"]
    mismatches(inputs_for(tokens)) do |text|
      old = [] of String
      text.scan(/(?<![\w.])"?([A-Za-z_][A-Za-z0-9_]*)"?\.(?=["A-Za-z_])/) { |match| old << match[1] }
      {old, TM.qualifiers_in(text)}
    end.should be_empty
  end

  it "recognizes column functions like the old SqlExpression::COLUMN_FUNCTION" do
    reference = /[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?/
    pattern = /\A\s*[A-Za-z_][A-Za-z0-9_]*\(\s*(?:#{reference}(?:\s*,\s*#{reference})*)?\s*\)(?:\s+(?:asc|desc))?(?:\s+nulls\s+(?:first|last))?\s*\z/i
    tokens = ["lower", "coalesce", "(", ")", "name", "t.name", ",", " ", "ASC", "desc", "nulls", "NULLS", "first", "last", "'x'", "1", "+", "K", "aſc"]
    mismatches(inputs_for(tokens, ["lower(name) DESC", "coalesce(a, b.c) asc nulls last", "f()", "f( )", "f(a,)"])) { |text| {text.matches?(pattern), TM.column_function?(text)} }.should be_empty
  end

  it "parses ORDER BY terms like the old Builder::ORDER_TERM" do
    tokens = ["name", "t.name", "_x", ".", " ", "ASC", "desc", "nulls", "first", "LAST", "é", "́", "1", "(", "K", "aſc"]
    mismatches(inputs_for(tokens, ["name DESC", " t.name asc nulls first ", "name nulls last"])) do |text|
      old = text.match(/\A\s*([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?)(?:\s+(asc|desc))?(?:\s+nulls\s+(first|last))?\s*\z/i).try { |match| {match[1], match[2]?, match[3]?} }
      new = TM.order_term(text).try { |term| {term.column, term.direction, term.nulls} }
      {old, new}
    end.should be_empty
  end

  it "finds raw ORDER BY directions like the old OrderSupport::RAW_DIRECTION" do
    tokens = ["lower(name)", "x", " ", "ASC", "desc", "nulls", "NULLS", "first", "last", "aſc", " "]
    mismatches(inputs_for(tokens)) do |text|
      old = text.match(/\s+(asc|desc)(\s+nulls\s+(first|last))?\s*\z/i).try { |match| {match.begin(0), match[1], match[3]?} }
      new = TM.raw_direction(text).try { |found| {found.index, found.direction, found.nulls} }
      {old, new}
    end.should be_empty
  end

  it "finds join qualifiers like the old JoinSupport.qualifier" do
    tokens = ["users", " ", "AS", "as", "aſ", "managers", "x", "\t", "ass"]
    mismatches(inputs_for(tokens)) do |text|
      old = (index = text.rindex(/\s+as\s+/i)) ? text[index..].sub(/\A\s+as\s+/i, "") : text
      {old, TM.join_qualifier(text)}
    end.should be_empty
  end

  it "finds raw join targets like the old JoinSupport::RAW_JOIN_TARGET" do
    pattern = /\bJOIN\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s+(?:AS\s+)?(?!ON\b|USING\b|INNER\b|LEFT\b|RIGHT\b|FULL\b|CROSS\b|NATURAL\b|JOIN\b)([A-Za-z_][A-Za-z0-9_]*))?/i
    tokens = SQL_TOKENS + ["CROSS", "NATURAL", "FULL", "RIGHT", "uſing", "ONx", "authors", "a"]
    mismatches(inputs_for(tokens)) { |text| {text.scan(pattern).map { |match| match[2]? || match[1] }, TM.raw_join_targets(text)} }.should be_empty
  end

  it "finds comparison binds like the old Encryption::LogFilter::COMPARISON" do
    pattern = /["`]?([A-Za-z_][A-Za-z0-9_]*)["`]?\s*(?:=|!=|<>|<=|>=|<|>|\bLIKE|\bILIKE)\s*(\?|\$\d+)/i
    mismatches(inputs_for(SQL_TOKENS)) do |text|
      old = [] of {String, String, Int32}
      text.scan(pattern) { |match| old << {match[1], match[2], match.begin(2)} }
      {old, TM.comparison_binds(text).map { |bind| {bind.column, bind.placeholder.text, bind.placeholder.index} }}
    end.should be_empty
  end

  it "finds IN-list binds like the old Encryption::LogFilter::IN_LIST" do
    pattern = /["`]?([A-Za-z_][A-Za-z0-9_]*)["`]?\s+(?:NOT\s+)?IN\s*\(([^)]*)\)/i
    mismatches(inputs_for(SQL_TOKENS)) do |text|
      old = [] of {String, Array({String, Int32})}
      text.scan(pattern) do |match|
        base = match.begin(2)
        found = [] of {String, Int32}
        match[2].scan(/\?|\$(\d+)/) { |placeholder| found << {placeholder[0], base + placeholder.begin(0)} }
        old << {match[1], found}
      end
      {old, TM.in_list_binds(text).map { |bind| {bind.column, bind.placeholders.map { |placeholder| {placeholder.text, placeholder.index} }} }}
    end.should be_empty
  end

  it "finds INSERT binds like the old Encryption::LogFilter::INSERT" do
    pattern = /INSERT\s+INTO\s+\S+\s*\(([^)]*)\)\s*VALUES\s*(.*)/im
    tokens = SQL_TOKENS + ["INSERT INTO", "users(", "users (", "a, b", ")", "VALUES (?, ?)", "\n", "x(y"]
    mismatches(inputs_for(tokens, ["INSERT INTO users(a,b) VALUES (?, $2)", "INSERT INTO t(a) x(b) VALUES ?"])) do |text|
      old = if match = pattern.match(text)
              base = match.begin(2)
              found = [] of {String, Int32}
              match[2].scan(/\?|\$(\d+)/) { |placeholder| found << {placeholder[0], base + placeholder.begin(0)} }
              {match[1], found}
            end
      new = TM.insert_binds(text).try { |binds| {binds.column_list, binds.placeholders.map { |placeholder| {placeholder.text, placeholder.index} }} }
      {old, new}
    end.should be_empty
  end

  it "validates email addresses like the old CommonFormats::EMAIL_REGEX" do
    tokens = ["user", "@", "example", ".", "com", "-", "+", "_", "1", "é", "K", "aſ", "٣", "x"]
    extra = ["user@example.com", "a.b+c@sub.example.co", "@example.com", "user@", "user@example", "user@-x.com", "user@ex_ample.com", "user@exa.c0m"]
    mismatches(inputs_for(tokens, extra)) { |text| {text.matches?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i), TM.email?(text)} }.should be_empty
  end

  it "validates URLs like the old CommonFormats::URL_REGEX" do
    pattern = /\Ahttps?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&\/\/=]*)\z/
    tokens = ["http://", "https://", "www.", "example", ".", "com", "/", "path", "?", "q=1", "(", ")", "-", "#", "a", "1234567", "x" * 300]
    extra = ["https://example.com", "http://www.example.com/a?b=c", "ftp://example.com", "https://example", "https://example.(x)", "https://a.b)c", "https://" + "a" * 257 + ".com"]
    mismatches(inputs_for(tokens, extra)) { |text| {text.matches?(pattern), TM.url?(text)} }.should be_empty
  end
  it "does work linear in the input length on adversarial input" do
    # Each block runs every matcher over text built from *count* repeats of a
    # piece that keeps a backtracking matcher busy. Quadrupling the input must
    # not take more than about eight times as long (a quadratic matcher would
    # take sixteen).
    pieces = ["a", " ", "1", "$", "(", "a.", "\"a\"", "JOIN a ", "INSERT INTO a(", "x IN (", "for ", "%{a", "/share/", "x as ", "'", "a = ", "K"]
    run_all = ->(count : Int32) do
      pieces.each do |piece|
        text = piece * count
        TM.simple_identifier?(text)
        TM.qualified_identifier?(text)
        TM.comparison_binds(text)
        TM.in_list_binds(text)
        TM.insert_binds(text)
        TM.qualifiers_in(text)
        TM.raw_join_targets(text)
        TM.join_qualifier(text)
        TM.column_function?(text)
        TM.order_term(text)
        TM.raw_direction(text)
        TM.statement_table(text)
        TM.locking_read?(text)
        TM.trailing_clause_keyword?(text)
        TM.sql_after_condition?(text)
        TM.normalize_sql_shape(text)
        TM.split_sql_words(text)
        TM.stdlib_path?(text)
        TM.frame_with_line?(text)
        TM.replace_named_placeholders(text) { |whole, _| whole }
        TM.replace_table_qualifier(text, "a", "b.")
        TM.redact_url_credentials("postgres://" + text)
        TM.email?(text)
        TM.url?("https://" + text)
        TM.remove_parenthesized_suffix(text)
        TM.mysql_literal_default?(text)
      end
    end
    measure = ->(count : Int32) { Array.new(3) { Time.measure { run_all.call(count) } }.min }
    small = measure.call(5_000)
    large = measure.call(20_000)
    (large / small).should be < 8.0
  end
end
