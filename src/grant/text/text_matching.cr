require "./character_class"
require "./character_scan"

# :nodoc:
#
# Hand-written matchers for the text patterns Grant checks on its default path
# (model definition, querying, saving, validating, logging and both adapters),
# so an app that uses Grant links no PCRE2. Each method names the regular
# expression it replaces and accepts and rejects exactly what that expression
# did, Unicode classes and case-insensitive folding included (see
# `Grant::CharacterClass`). `spec/grant/text/text_matching_spec.cr` compares
# every method with its original expression over a table of inputs and seeded
# fuzz corpora.
#
# Single-byte text (every character one byte, which is what SQL, URLs and
# identifiers almost always are) is answered by scanning its bytes in place:
# no copy of the text, and a library `memchr` to reach the rare byte a pattern
# starts with. Text that holds a multibyte character goes to
# `Grant::TextMatching::CharacterScan`, which reads it as characters so the
# Unicode classes and case folds apply. A few methods whose pattern can only
# match ASCII bytes scan any text's bytes directly.
#
# Every method makes one pass over its input (a few look back or forward a
# bounded distance), so the work is linear in the input length. Indices are
# character indices, as `Regex::MatchData#begin` reports them; in single-byte
# text a byte index is the character index.
module Grant::TextMatching
  alias CC = Grant::CharacterClass

  # A bound placeholder found in SQL: its text (`?` or `$3`) and character index.
  record Placeholder, text : String, index : Int32

  # The column a placeholder is compared with in a `column <op> ?` predicate.
  record ComparisonBind, column : String, placeholder : Placeholder

  # A `column [NOT] IN (...)` predicate: the column and the placeholders inside
  # the parentheses.
  record InListBind, column : String, placeholders : Array(Placeholder)

  # The column list and the placeholders of an `INSERT INTO t (...) VALUES ...`.
  record InsertBinds, column_list : String, placeholders : Array(Placeholder)

  # A trailing ORDER BY direction: where its leading white space begins, the
  # direction word and the NULL placement word as written.
  record RawDirection, index : Int32, direction : String, nulls : String?

  # One ORDER BY term written as `column [ASC|DESC] [NULLS FIRST|LAST]`.
  record OrderTerm, column : String, direction : String?, nulls : String?

  # Replaces `/\A[A-Za-z_][A-Za-z0-9_]*\z/`: a bare SQL identifier. The class
  # is ASCII, so the bytes of any text answer it.
  def self.simple_identifier?(text : String) : Bool
    bytes = text.to_slice
    ident_end(bytes, 0) == bytes.size && !bytes.empty?
  end

  # Replaces `/\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?\z/`: a
  # column name or a `table.column` pair.
  def self.qualified_identifier?(text : String) : Bool
    bytes = text.to_slice
    first_end = ident_end(bytes, 0)
    return false if first_end == 0
    return true if first_end == bytes.size
    return false unless bytes.unsafe_fetch(first_end) === '.'
    ident_end(bytes, first_end + 1) == bytes.size && first_end + 1 < bytes.size
  end

  # Replaces `/\A[A-Za-z][A-Za-z0-9_., ]*\z/`: the characters a vendor lock
  # clause may hold.
  def self.lock_clause?(text : String) : Bool
    bytes = text.to_slice
    return false unless letter_byte?(byte_at(bytes, 0))
    index = 1
    while index < bytes.size
      return false unless lock_byte?(bytes.unsafe_fetch(index))
      index += 1
    end
    true
  end

  # Replaces the group of `/\A([A-Za-z][A-Za-z0-9+.\-]*):/`: the scheme of a
  # URL as written, or `nil` when it has none.
  def self.url_scheme(url : String) : String?
    bytes = url.to_slice
    scheme_end = scheme_end(bytes) || return
    return unless byte_at(bytes, scheme_end) === ':'
    url.byte_slice(0, scheme_end)
  end

  # Replaces `url.sub(/\A([A-Za-z][A-Za-z0-9+.\-]*:\/\/)[^?#]*@/, "\\1***@")`:
  # hides the user information of a URL, up to its last `@` before any query
  # or fragment.
  def self.redact_url_credentials(url : String) : String
    bytes = url.to_slice
    scheme_end = scheme_end(bytes) || return url
    return url unless byte_at(bytes, scheme_end) === ':' && byte_at(bytes, scheme_end + 1) === '/' && byte_at(bytes, scheme_end + 2) === '/'
    authority_start = scheme_end + 3
    last_at = -1
    index = authority_start
    while index < bytes.size
      byte = bytes.unsafe_fetch(index)
      break if byte === '?' || byte === '#'
      last_at = index if byte === '@'
      index += 1
    end
    return url if last_at < 0
    join_bytes(bytes[0, authority_start], "***@".to_slice, bytes[last_at + 1..])
  end

  # Replaces `url.sub(/\Asqlite3?:(?:\/\/)?/, "")`: a SQLite URL without its
  # scheme and the optional `//`.
  def self.strip_sqlite_scheme(url : String) : String
    rest = if url.starts_with?("sqlite3:")
             8
           elsif url.starts_with?("sqlite:")
             7
           else
             return url
           end
    bytes = url.to_slice
    rest += 2 if byte_at(bytes, rest) === '/' && byte_at(bytes, rest + 1) === '/'
    url.byte_slice(rest, bytes.size - rest)
  end

  # Replaces `url.sub(/\Apostgres(ql)?:/, replacement)`.
  def self.replace_postgres_scheme(url : String, replacement : String) : String
    if url.starts_with?("postgresql:")
      join_bytes(replacement.to_slice, url.to_slice[11..])
    elsif url.starts_with?("postgres:")
      join_bytes(replacement.to_slice, url.to_slice[9..])
    else
      url
    end
  end

  # Replaces `url.matches?(/[?&]encoding=/i)`. No character outside ASCII
  # folds to a letter of `encoding`, so the bytes of any text answer it.
  def self.encoding_option?(url : String) : Bool
    bytes = url.to_slice
    index = 0
    while index < bytes.size
      byte = bytes.unsafe_fetch(index)
      return true if (byte === '?' || byte === '&') && keyword_at?(bytes, index + 1, "encoding") && byte_at(bytes, index + 9) === '='
      index += 1
    end
    false
  end

  # Replaces `piece.sub(/\s+(?:ASC|DESC)\z/i, "")`: an index column without its
  # trailing sort direction.
  def self.strip_trailing_sort_direction(piece : String) : String
    return CharacterScan.strip_trailing_sort_direction(piece) unless piece.single_byte_optimizable?
    bytes = piece.to_slice
    size = bytes.size
    word_start = if keyword_at?(bytes, size - 3, "asc")
                   size - 3
                 elsif keyword_at?(bytes, size - 4, "desc")
                   size - 4
                 end
    return piece unless word_start && space_byte?(byte_at(bytes, word_start - 1))
    piece.byte_slice(0, space_run_start(bytes, word_start - 1))
  end

  # Replaces `text.gsub(/\$\d+/) { |match| ... }`: yields each `$<digits>`
  # placeholder and puts the block's result in its place.
  def self.replace_numbered_placeholders(text : String, & : String -> String) : String
    bytes = text.to_slice
    dollar = bytes.index('$'.ord.to_u8) || return text
    return CharacterScan.replace_numbered_placeholders(text) { |match| yield match } unless text.single_byte_optimizable?
    String.build(bytes.size) do |io|
      copied = 0
      while dollar
        digits_end = digit_run_end(bytes, dollar + 1)
        if digits_end > dollar + 1
          io.write(bytes[copied, dollar - copied])
          io << yield ascii_string(bytes[dollar, digits_end - dollar])
          copied = digits_end
        end
        dollar = bytes.index('$'.ord.to_u8, Math.max(digits_end, dollar + 1))
      end
      io.write(bytes[copied..])
    end
  end

  # Replaces `text.gsub(/(?<![\w."`])#{Regex.escape(table)}\./, replacement)`:
  # rewrites `table.` qualifiers that are not part of a longer name. The
  # *replacement* is written as given (`gsub` with a string would expand `\0`
  # and the like); callers pass identifiers or quoted table names, which hold
  # no backslashes.
  def self.replace_table_qualifier(text : String, table : String, replacement : String) : String
    unless text.single_byte_optimizable? && table.single_byte_optimizable?
      return CharacterScan.replace_table_qualifier(text, table, replacement)
    end
    bytes = text.to_slice
    name = table.to_slice
    first = name.empty? ? '.'.ord.to_u8 : name.unsafe_fetch(0)
    candidate = bytes.index(first)
    builder = nil
    copied = 0
    while candidate
      stop = candidate + name.size
      previous = byte_at(bytes, candidate - 1)
      if byte_at(bytes, stop) === '.' && bytes[candidate, name.size] == name &&
         !(word_byte?(previous) || previous === '.' || previous === '"' || previous === '`')
        io = builder ||= String::Builder.new(bytes.size + replacement.bytesize)
        io.write(bytes[copied, candidate - copied])
        io << replacement
        copied = stop + 1
        candidate = bytes.index(first, stop + 1)
      else
        candidate = bytes.index(first, candidate + 1)
      end
    end
    return text unless io = builder
    io.write(bytes[copied..])
    io.to_s
  end

  # Replaces `query.split(/([a-zA-Z0-9_$']+)/)`: the text between runs of
  # word characters and the runs themselves, alternating, starting and ending
  # with a (possibly empty) gap, as `String#split` with a capture group yields.
  # The class is ASCII, so the bytes of any text answer it.
  def self.split_sql_words(query : String) : Array(String)
    bytes = query.to_slice
    return [""] if bytes.empty?
    parts = [] of String
    gap_start = 0
    index = 0
    while index < bytes.size
      if sql_word_byte?(bytes.unsafe_fetch(index))
        run_end = index + 1
        while run_end < bytes.size && sql_word_byte?(bytes.unsafe_fetch(run_end))
          run_end += 1
        end
        parts << String.new(bytes[gap_start, index - gap_start])
        parts << ascii_string(bytes[index, run_end - index])
        gap_start = index = run_end
      else
        index += 1
      end
    end
    parts << String.new(bytes[gap_start..])
    parts
  end

  # Replaces `word =~ /\d+/`: whether *text* holds a decimal digit.
  def self.contains_digit?(text : String) : Bool
    return CharacterScan.contains_digit?(text) unless text.single_byte_optimizable?
    text.to_slice.any? { |byte| digit_byte?(byte) }
  end

  # Replaces `text =~ /KEYWORD/i` for an ASCII *keyword*: whether *text*
  # contains it, ignoring case.
  def self.contains_ignoring_case?(text : String, keyword : String) : Bool
    return CharacterScan.contains_ignoring_case?(text, keyword) unless text.single_byte_optimizable?
    bytes = text.to_slice
    return true if keyword.empty?
    finder = LetterFinder.new(bytes, keyword.to_unsafe.value)
    while candidate = finder.next_at
      return true if keyword_at?(bytes, candidate, keyword)
      finder.advance(candidate + 1)
    end
    false
  end

  # Replaces the chain
  # `sql.gsub(/\b\d+\b/, "?").gsub(/'[^']*'/, "?").gsub(/\$\d+/, "?").gsub(/\s+/, " ")`:
  # a statement with its literals and placeholders replaced, for grouping
  # statements of the same shape.
  def self.normalize_sql_shape(sql : String) : String
    return CharacterScan.normalize_sql_shape(sql) unless sql.single_byte_optimizable?
    shape = replace_standalone_numbers(sql)
    shape = replace_quoted_strings(shape)
    shape = replace_numbered_placeholders(shape) { "?" }
    collapse_spaces(shape)
  end

  # Replaces `/\bfor\s+(update|share|no\s+key\s+update|key\s+share)\b/i`: a
  # read that takes row locks.
  def self.locking_read?(sql : String) : Bool
    return CharacterScan.locking_read?(sql) unless sql.single_byte_optimizable?
    bytes = sql.to_slice
    finder = LetterFinder.new(bytes, 'f'.ord.to_u8)
    while index = finder.next_at
      finder.advance(index + 1)
      next unless keyword_at?(bytes, index, "for") && boundary_before?(bytes, index)
      start = spaces_after(bytes, index + 3) || next
      return true if keyword_sequence_end(bytes, start, {"update"}).try { |stop| boundary_before?(bytes, stop) }
      return true if keyword_sequence_end(bytes, start, {"share"}).try { |stop| boundary_before?(bytes, stop) }
      return true if keyword_sequence_end(bytes, start, {"no", "key", "update"}).try { |stop| boundary_before?(bytes, stop) }
      return true if keyword_sequence_end(bytes, start, {"key", "share"}).try { |stop| boundary_before?(bytes, stop) }
    end
    false
  end

  # Replaces `/\b(ORDER\s+BY|LIMIT|OFFSET|GROUP\s+BY)\b/i`: whether a raw
  # clause holds SQL that does not belong in a WHERE condition.
  def self.trailing_clause_keyword?(clause : String) : Bool
    return CharacterScan.trailing_clause_keyword?(clause) unless clause.single_byte_optimizable?
    bytes = clause.to_slice
    # Every keyword holds an `o` or an `i`; long text without either has none.
    return false unless short?(bytes) || has_letter?(bytes, 'o'.ord.to_u8) || has_letter?(bytes, 'i'.ord.to_u8)
    clause_keyword_in?(bytes, skip_quoted: false, having: false)
  end

  # Whether a raw clause holds SQL that follows a WHERE condition: the
  # `.trailing_clause_keyword?` words or `HAVING`, each a whole word in any
  # case. Text inside single-quoted literals and double-quoted or backtick
  # identifiers is skipped, so `WHERE title = 'LIMIT'` is a plain condition.
  def self.sql_after_condition?(clause : String) : Bool
    return CharacterScan.sql_after_condition?(clause) unless clause.single_byte_optimizable?
    bytes = clause.to_slice
    # Every keyword holds an `o` or an `i`; long text without either has none.
    return false unless short?(bytes) || has_letter?(bytes, 'o'.ord.to_u8) || has_letter?(bytes, 'i'.ord.to_u8)
    clause_keyword_in?(bytes, skip_quoted: true, having: true)
  end

  # Whether a raw clause joins another table: the word `JOIN` in any case,
  # outside quoted literals and identifiers.
  def self.join_clause?(clause : String) : Bool
    return CharacterScan.join_clause?(clause) unless clause.single_byte_optimizable?
    bytes = clause.to_slice
    return false unless short?(bytes) || has_letter?(bytes, 'j'.ord.to_u8)
    each_word(bytes, skip_quoted: true) do |start, stop|
      return true if stop - start == 4 && keyword_at?(bytes, start, "join")
    end
    false
  end

  # Replaces `type.sub(/\ATIMESTAMP(\(\d+\))?/i, replacement)`: a column type
  # whose leading `TIMESTAMP` (and its precision) is rewritten.
  def self.replace_leading_timestamp(type : String, replacement : String) : String
    return CharacterScan.replace_leading_timestamp(type, replacement) unless type.single_byte_optimizable?
    bytes = type.to_slice
    return type unless keyword_at?(bytes, 0, "timestamp")
    stop = 9
    if byte_at(bytes, stop) === '('
      digits_end = digit_run_end(bytes, stop + 1)
      stop = digits_end + 1 if digits_end > stop + 1 && byte_at(bytes, digits_end) === ')'
    end
    join_bytes(replacement.to_slice, bytes[stop..])
  end

  # Replaces `/\A(?:'(?:[^'\\]|''|\\.)*'|[-+]?\d+(?:\.\d+)?)\z/`: a MySQL
  # default that is a quoted string or a signed decimal number.
  def self.mysql_literal_default?(text : String) : Bool
    return CharacterScan.mysql_literal_default?(text) unless text.single_byte_optimizable?
    bytes = text.to_slice
    return quoted_mysql_string?(bytes) if byte_at(bytes, 0) === '\''
    index = byte_at(bytes, 0) === '-' || byte_at(bytes, 0) === '+' ? 1 : 0
    integer_end = digit_run_end(bytes, index)
    return false if integer_end == index
    return true if integer_end == bytes.size
    return false unless bytes.unsafe_fetch(integer_end) === '.'
    fraction_end = digit_run_end(bytes, integer_end + 1)
    fraction_end > integer_end + 1 && fraction_end == bytes.size
  end

  # Replaces `/\A(CURRENT_TIMESTAMP|CURRENT_DATE|CURRENT_TIME|NOW|LOCALTIMESTAMP|LOCALTIME)(\(\d*\))?\z/i`
  # (with *mysql*) and `/\ACURRENT_(TIMESTAMP|DATE|TIME)\z/i`: a time keyword
  # that is a column default as written.
  def self.bare_time_default?(text : String, *, mysql : Bool) : Bool
    return CharacterScan.bare_time_default?(text, mysql: mysql) unless text.single_byte_optimizable?
    bytes = text.to_slice
    unless mysql
      return {"current_timestamp", "current_date", "current_time"}.any? { |keyword| keyword.bytesize == bytes.size && keyword_at?(bytes, 0, keyword) }
    end
    {"current_timestamp", "current_date", "current_time", "now", "localtimestamp", "localtime"}.any? do |keyword|
      stop = keyword.bytesize
      next false unless stop <= bytes.size && keyword_at?(bytes, 0, keyword)
      next true if stop == bytes.size
      next false unless bytes.unsafe_fetch(stop) === '('
      digits_end = digit_run_end(bytes, stop + 1)
      digits_end + 1 == bytes.size && bytes.unsafe_fetch(digits_end) === ')'
    end
  end

  # Replaces the group of `/\A(?:DATETIME|TIMESTAMP|TIME)\((\d+)\)/i`: the
  # fractional digits of a time column type.
  def self.time_type_precision(type : String) : String?
    return CharacterScan.time_type_precision(type) unless type.single_byte_optimizable?
    bytes = type.to_slice
    {"datetime", "timestamp", "time"}.each do |keyword|
      size = keyword.bytesize
      next unless keyword_at?(bytes, 0, keyword) && byte_at(bytes, size) === '('
      digits_end = digit_run_end(bytes, size + 1)
      return ascii_string(bytes[size + 1, digits_end - size - 1]) if digits_end > size + 1 && byte_at(bytes, digits_end) === ')'
    end
    nil
  end

  # Replaces `/\A(CURRENT_TIMESTAMP|CURRENT_TIME|NOW|LOCALTIMESTAMP|LOCALTIME)\z/i`.
  def self.current_time_keyword?(text : String) : Bool
    return CharacterScan.current_time_keyword?(text) unless text.single_byte_optimizable?
    bytes = text.to_slice
    {"current_timestamp", "current_time", "now", "localtimestamp", "localtime"}.any? do |keyword|
      keyword.bytesize == bytes.size && keyword_at?(bytes, 0, keyword)
    end
  end

  # Replaces `text.sub(/\(\d+\)/, "")`: drops the first parenthesized number.
  def self.remove_parenthesized_number(text : String) : String
    return CharacterScan.remove_parenthesized_number(text) unless text.single_byte_optimizable?
    bytes = text.to_slice
    open = 0
    while open < bytes.size
      if bytes.unsafe_fetch(open) === '('
        digits_end = digit_run_end(bytes, open + 1)
        if digits_end > open + 1 && byte_at(bytes, digits_end) === ')'
          return join_bytes(bytes[0, open], bytes[digits_end + 1..])
        end
        open = digits_end
      else
        open += 1
      end
    end
    text
  end

  # Replaces `name.sub(/\s*\(.*\)/, "")`: drops the first parenthesized part
  # (with the white space before it) up to the last `)` on that line.
  def self.remove_parenthesized_suffix(name : String) : String
    return CharacterScan.remove_parenthesized_suffix(name) unless name.single_byte_optimizable?
    bytes = name.to_slice
    open = bytes.index('('.ord.to_u8)
    while open
      # `.` stops at a newline, so the `)` must lie on the line of the `(`.
      line_end = bytes.index('\n'.ord.to_u8, open + 1) || bytes.size
      if close = bytes[open + 1, line_end - open - 1].index(')'.ord.to_u8)
        close += open + 1
        while later = bytes[close + 1, line_end - close - 1].index(')'.ord.to_u8)
          close += later + 1
        end
        return join_bytes(bytes[0, space_run_start(bytes, open)], bytes[close + 1..])
      end
      # No `(` later on this line has a `)` after it either.
      open = bytes.index('('.ord.to_u8, line_end)
    end
    name
  end

  # Replaces `clause.sub(/\AWHERE\s+/i, "")`.
  def self.strip_leading_where(clause : String) : String
    return CharacterScan.strip_leading_where(clause) unless clause.single_byte_optimizable?
    bytes = clause.to_slice
    return clause unless keyword_at?(bytes, 0, "where")
    rest = spaces_after(bytes, 5) || return clause
    clause.byte_slice(rest, bytes.size - rest)
  end

  # Replaces the first group of
  # `/\b(?:FROM|INTO|UPDATE)\s+(?:ONLY\s+)?[`"\[]?([\w.$]+)/i`: the table a
  # statement reads or writes, as written.
  def self.statement_table(sql : String) : String?
    return CharacterScan.statement_table(sql) unless sql.single_byte_optimizable?
    bytes = sql.to_slice
    each_word(bytes, skip_quoted: false) do |start, stop|
      next unless statement_keyword?(bytes, start, stop)
      after = spaces_after(bytes, stop) || next
      if stop_of_only = only_keyword_end(bytes, after)
        if table = table_reference_at(bytes, stop_of_only)
          return table
        end
      end
      if table = table_reference_at(bytes, after)
        return table
      end
    end
    nil
  end

  # Replaces `/\A(.+?:\d+(?::\d+)?)(.*)\z/m` (whose two groups rebuild the
  # frame): whether a backtrace frame carries a `:line` after its first
  # character.
  def self.frame_with_line?(frame : String) : Bool
    return CharacterScan.frame_with_line?(frame) unless frame.single_byte_optimizable?
    bytes = frame.to_slice
    colon = bytes.size > 1 ? bytes.index(':'.ord.to_u8, 1) : nil
    while colon
      return true if digit_byte?(byte_at(bytes, colon + 1))
      colon = bytes.index(':'.ord.to_u8, colon + 1)
    end
    false
  end

  # Replaces `%r{/(?:share/[\w.-]*crystal[\w.-]*|crystal)/src/}`: whether a
  # path lies in the Crystal standard library.
  def self.stdlib_path?(path : String) : Bool
    return CharacterScan.stdlib_path?(path) unless path.single_byte_optimizable?
    bytes = path.to_slice
    # Every match ends in `/src/`: find each, then read the directory before it.
    index = 0
    while index + 5 <= bytes.size
      byte = bytes.unsafe_fetch(index + 4)
      return true if byte === '/' && src_directory_at?(bytes, index) && stdlib_directory_before?(bytes, index)
      # The byte at `index + 4` starts the next candidate only when it is a `/`.
      index += byte === '/' ? 4 : (byte === 'c' || byte === 'r' || byte === 's' ? 1 : 5)
    end
    false
  end

  # Replaces `/\A\$2[abxy]?\$\d{2}\$[.\/A-Za-z0-9]{53}\z/`: the shape of a
  # bcrypt hash.
  def self.bcrypt_digest?(digest : String) : Bool
    return CharacterScan.bcrypt_digest?(digest) unless digest.single_byte_optimizable?
    bytes = digest.to_slice
    return false unless bytes.size.in?(59, 60)
    body_start = bcrypt_body_start(bytes) || return false
    return false unless bytes.size - body_start == 53
    (body_start...bytes.size).all? { |index| bcrypt_byte?(bytes.unsafe_fetch(index)) }
  end

  # Replaces `template.gsub(/%\{(\w+)\}/) { |whole, match| ... }`: yields each
  # `%{name}` placeholder and its name, and puts the block's result in its place.
  def self.replace_named_placeholders(template : String, & : String, String -> String) : String
    unless template.single_byte_optimizable?
      return CharacterScan.replace_named_placeholders(template) { |whole, name| yield whole, name }
    end
    bytes = template.to_slice
    percent = bytes.index('%'.ord.to_u8) || return template
    String.build(bytes.size) do |io|
      copied = 0
      while percent
        name_end = percent + 2
        if byte_at(bytes, percent + 1) === '{'
          while name_end < bytes.size && word_byte?(bytes.unsafe_fetch(name_end))
            name_end += 1
          end
          if name_end > percent + 2 && byte_at(bytes, name_end) === '}'
            io.write(bytes[copied, percent - copied])
            io << yield ascii_string(bytes[percent, name_end + 1 - percent]), ascii_string(bytes[percent + 2, name_end - percent - 2])
            copied = name_end + 1
            percent = bytes.index('%'.ord.to_u8, copied)
            next
          end
        end
        percent = bytes.index('%'.ord.to_u8, percent + 1)
      end
      io.write(bytes[copied..])
    end
  end

  # Replaces the `/(?:s|x|z|ch|sh)\z/` and `/[^aeiou]y\z/` suffix rules of the
  # English pluralizer.
  def self.plural_suffix_es?(word : String) : Bool
    word.ends_with?('s') || word.ends_with?('x') || word.ends_with?('z') || word.ends_with?("ch") || word.ends_with?("sh")
  end

  # :ditto:
  def self.consonant_y_ending?(word : String) : Bool
    return false unless word.size >= 2 && word.ends_with?('y')
    !word[word.size - 2].in?('a', 'e', 'i', 'o', 'u')
  end

  # Replaces scanning `/(?<![\w.])"?([A-Za-z_][A-Za-z0-9_]*)"?\.(?=["A-Za-z_])/`:
  # every `table.` qualifier a raw condition names.
  def self.qualifiers_in(statement : String) : Array(String)
    return CharacterScan.qualifiers_in(statement) unless statement.single_byte_optimizable?
    bytes = statement.to_slice
    found = [] of String
    index = 0
    while index < bytes.size
      previous = byte_at(bytes, index - 1)
      if !(word_byte?(previous) || previous === '.') && (qualifier = qualifier_at(bytes, index))
        name_start, name_end, dot = qualifier
        found << ascii_string(bytes[name_start, name_end - name_start])
        index = dot + 1
      else
        index += 1
      end
    end
    found
  end

  # Replaces
  # `/\A\s*[A-Za-z_][A-Za-z0-9_]*\(\s*(?:REF(?:\s*,\s*REF)*)?\s*\)(?:\s+(?:asc|desc))?(?:\s+nulls\s+(?:first|last))?\s*\z/i`
  # with `REF = [A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?`: a
  # function applied to column references only.
  def self.column_function?(text : String) : Bool
    return CharacterScan.column_function?(text) unless text.single_byte_optimizable?
    bytes = text.to_slice
    index = skip_spaces(bytes, 0)
    name_end = ident_end(bytes, index)
    return false if name_end == index || !(byte_at(bytes, name_end) === '(')
    index = skip_spaces(bytes, name_end + 1)
    if reference_end = column_reference_end(bytes, index)
      index = reference_end
      loop do
        comma = skip_spaces(bytes, index)
        break unless byte_at(bytes, comma) === ','
        reference_end = column_reference_end(bytes, skip_spaces(bytes, comma + 1)) || return false
        index = reference_end
      end
    end
    index = skip_spaces(bytes, index)
    return false unless byte_at(bytes, index) === ')'
    !sort_tail(bytes, index + 1).nil?
  end

  # Replaces `/\A\s*([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?)(?:\s+(asc|desc))?(?:\s+nulls\s+(first|last))?\s*\z/i`:
  # an ORDER BY term naming a column, or `nil`.
  def self.order_term(term : String) : OrderTerm?
    return CharacterScan.order_term(term) unless term.single_byte_optimizable?
    bytes = term.to_slice
    start = skip_spaces(bytes, 0)
    column_end = ident_end(bytes, start)
    return if column_end == start
    if byte_at(bytes, column_end) === '.'
      qualified_end = ident_end(bytes, column_end + 1)
      column_end = qualified_end if qualified_end > column_end + 1
    end
    tail = sort_tail(bytes, column_end) || return
    direction_start, direction_stop, nulls_start, nulls_stop = tail
    OrderTerm.new(ascii_string(bytes[start, column_end - start]),
      direction_start < 0 ? nil : ascii_string(bytes[direction_start, direction_stop - direction_start]),
      nulls_start < 0 ? nil : ascii_string(bytes[nulls_start, nulls_stop - nulls_start]))
  end

  # Replaces `/\s+(asc|desc)(\s+nulls\s+(first|last))?\s*\z/i`: the direction
  # that ends a raw ORDER BY term, or `nil`.
  def self.raw_direction(part : String) : RawDirection?
    return CharacterScan.raw_direction(part) unless part.single_byte_optimizable?
    bytes = part.to_slice
    stop = space_run_start(bytes, bytes.size)
    nulls = nil
    placement_start = trailing_keyword_start(bytes, stop, {"first", "last"})
    if placement_start && (nulls_start = keyword_before_spaces(bytes, placement_start, "nulls"))
      nulls = ascii_string(bytes[placement_start, stop - placement_start])
      stop = space_run_start(bytes, nulls_start)
    end
    direction_start = trailing_keyword_start(bytes, stop, {"asc", "desc"}) || return
    return unless space_byte?(byte_at(bytes, direction_start - 1))
    RawDirection.new(space_run_start(bytes, direction_start - 1), ascii_string(bytes[direction_start, stop - direction_start]), nulls)
  end

  # Replaces `table.rindex(/\s+as\s+/i)` followed by
  # `table[index..].sub(/\A\s+as\s+/i, "")`: the alias of a joined table, or
  # the table itself when it has none.
  def self.join_qualifier(table : String) : String
    return CharacterScan.join_qualifier(table) unless table.single_byte_optimizable?
    bytes = table.to_slice
    alias_start = -1
    index = 0
    while index < bytes.size
      if space_byte?(bytes.unsafe_fetch(index))
        run_end = skip_spaces(bytes, index)
        if keyword_at?(bytes, run_end, "as") && (after = spaces_after(bytes, run_end + 2))
          alias_start = index = after
        else
          index = run_end
        end
      else
        index += 1
      end
    end
    alias_start < 0 ? table : table.byte_slice(alias_start, bytes.size - alias_start)
  end

  # Replaces scanning
  # `/\bJOIN\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s+(?:AS\s+)?(?!ON\b|USING\b|INNER\b|LEFT\b|RIGHT\b|FULL\b|CROSS\b|NATURAL\b|JOIN\b)([A-Za-z_][A-Za-z0-9_]*))?/i`
  # and taking `match[2]? || match[1]`: the alias (or table) each raw JOIN
  # makes available.
  def self.raw_join_targets(clause : String) : Array(String)
    return CharacterScan.raw_join_targets(clause) unless clause.single_byte_optimizable?
    bytes = clause.to_slice
    found = [] of String
    index = 0
    while index < bytes.size
      if !word_byte?(bytes.unsafe_fetch(index)) || word_byte?(byte_at(bytes, index - 1))
        index += 1
        next
      end
      word_end = word_end(bytes, index)
      if word_end - index == 4 && keyword_at?(bytes, index, "join") && (table_start = spaces_after(bytes, word_end))
        table_end = ident_end(bytes, table_start)
        if table_end > table_start
          if alias_range = join_alias_range(bytes, table_end)
            alias_start, alias_end = alias_range
            found << ascii_string(bytes[alias_start, alias_end - alias_start])
            index = alias_end
          else
            found << ascii_string(bytes[table_start, table_end - table_start])
            index = table_end
          end
          next
        end
      end
      index = word_end
    end
    found
  end

  # Replaces scanning `/["`]?([A-Za-z_][A-Za-z0-9_]*)["`]?\s*(?:=|!=|<>|<=|>=|<|>|\bLIKE|\bILIKE)\s*(\?|\$\d+)/i`:
  # every `column <op> placeholder` predicate.
  def self.comparison_binds(query : String) : Array(ComparisonBind)
    return CharacterScan.comparison_binds(query) unless query.single_byte_optimizable?
    bytes = query.to_slice
    found = [] of ComparisonBind
    index = 0
    while index < bytes.size
      name_start = log_quote_byte?(bytes.unsafe_fetch(index)) ? index + 1 : index
      name_end = ident_end(bytes, name_start)
      if name_end > name_start
        if placeholder = comparison_placeholder(bytes, name_end)
          found << ComparisonBind.new(ascii_string(bytes[name_start, name_end - name_start]), placeholder)
          index = placeholder.index + placeholder.text.bytesize
        else
          # Any later start inside the same name reaches the same operator
          # position and fails the same way.
          index = name_end
        end
      else
        index += 1
      end
    end
    found
  end

  # Replaces scanning `/["`]?([A-Za-z_][A-Za-z0-9_]*)["`]?\s+(?:NOT\s+)?IN\s*\(([^)]*)\)/i`
  # and then `/\?|\$(\d+)/` inside the parentheses.
  def self.in_list_binds(query : String) : Array(InListBind)
    return CharacterScan.in_list_binds(query) unless query.single_byte_optimizable?
    bytes = query.to_slice
    closes = CloseParenFinder.new(bytes)
    found = [] of InListBind
    index = 0
    while index < bytes.size
      name_start = log_quote_byte?(bytes.unsafe_fetch(index)) ? index + 1 : index
      name_end = ident_end(bytes, name_start)
      if name_end > name_start
        if list = in_list_range(bytes, closes, name_end)
          found << InListBind.new(ascii_string(bytes[name_start, name_end - name_start]), placeholders_in(bytes, list[0], list[1]))
          index = list[1] + 1
        else
          index = name_end
        end
      else
        index += 1
      end
    end
    found
  end

  # Replaces `/INSERT\s+INTO\s+\S+\s*\(([^)]*)\)\s*VALUES\s*(.*)/im` and then
  # `/\?|\$(\d+)/` over the VALUES part.
  def self.insert_binds(query : String) : InsertBinds?
    return CharacterScan.insert_binds(query) unless query.single_byte_optimizable?
    bytes = query.to_slice
    closes = CloseParenFinder.new(bytes)
    finder = LetterFinder.new(bytes, 'i'.ord.to_u8)
    while index = finder.next_at
      finder.advance(index + 1)
      next unless keyword_at?(bytes, index, "insert")
      into = spaces_after(bytes, index + 6) || next
      next unless keyword_at?(bytes, into, "into")
      target_start = spaces_after(bytes, into + 4) || next
      target_end = target_start
      while target_end < bytes.size && !space_byte?(bytes.unsafe_fetch(target_end))
        target_end += 1
      end
      next if target_end == target_start
      if binds = insert_binds_after_target(bytes, closes, target_start, target_end)
        return binds
      end
    end
    nil
  end

  # Replaces `/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i`.
  def self.email?(value : String) : Bool
    return CharacterScan.email?(value) unless value.single_byte_optimizable?
    bytes = value.to_slice
    at = bytes.index('@'.ord.to_u8) || return false
    return false if at == 0
    (0...at).each do |index|
      return false unless email_local_byte?(bytes.unsafe_fetch(index))
    end
    email_domain?(bytes, at + 1)
  end

  # Replaces
  # `/\Ahttps?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&\/\/=]*)\z/`.
  # Every class is ASCII and the pattern spans the whole text, so the bytes of
  # any text answer it.
  def self.url?(value : String) : Bool
    prefix = if value.starts_with?("https://")
               8
             elsif value.starts_with?("http://")
               7
             else
               return false
             end
    bytes = value.to_slice
    # The host and top-level domain classes lie inside the path class, so a
    # match is path characters from the prefix to the end.
    (prefix...bytes.size).each do |index|
      return false unless url_path_byte?(bytes.unsafe_fetch(index))
    end
    return true if url_host_and_tld?(bytes, prefix)
    bytes[prefix, Math.min(4, bytes.size - prefix)] == "www.".to_slice && url_host_and_tld?(bytes, prefix + 4)
  end

  # --- byte classes ----------------------------------------------------------
  #
  # ASCII classes as two 64-bit sets: bit n of *low* is byte n, bit n of *high*
  # is byte 64 + n. A byte of 0x80 or more (part of a multibyte character, or
  # an invalid byte) belongs to none of them, as the character it is part of
  # belongs to no ASCII class.

  private macro byte_class(name, low, high)
    @[AlwaysInline]
    private def self.{{name.id}}(byte : UInt8) : Bool
      if byte < 64
        ({{low}} >> byte) & 1 == 1
      else
        byte < 128 && ({{high}} >> (byte &- 64)) & 1 == 1
      end
    end
  end

  # [A-Za-z0-9_], `\w` in ASCII
  byte_class word_byte?, 0x03FF000000000000_u64, 0x07FFFFFE87FFFFFE_u64
  # [ \t\n\v\f\r], `\s` in ASCII
  byte_class space_byte?, 0x0000000100003E00_u64, 0x0000000000000000_u64
  # [A-Za-z]
  byte_class letter_byte?, 0x0000000000000000_u64, 0x07FFFFFE07FFFFFE_u64
  # [0-9], `\d` in ASCII
  byte_class digit_byte?, 0x03FF000000000000_u64, 0x0000000000000000_u64
  # [a-zA-Z0-9_$']
  byte_class sql_word_byte?, 0x03FF009000000000_u64, 0x07FFFFFE87FFFFFE_u64
  # [A-Za-z0-9_., ]
  byte_class lock_byte?, 0x03FF500100000000_u64, 0x07FFFFFE87FFFFFE_u64
  # [A-Za-z0-9+.\-]
  byte_class scheme_byte?, 0x03FF680000000000_u64, 0x07FFFFFE07FFFFFE_u64
  # [-a-zA-Z0-9@:%._\+~#=]
  byte_class url_host_byte?, 0x27FF682800000000_u64, 0x47FFFFFE87FFFFFF_u64
  # [a-zA-Z0-9()]
  byte_class url_tld_byte?, 0x03FF030000000000_u64, 0x07FFFFFE07FFFFFE_u64
  # [-a-zA-Z0-9()@:%_\+.~#?&\/=]
  byte_class url_path_byte?, 0xA7FFEB6800000000_u64, 0x47FFFFFE87FFFFFF_u64
  # [.\/A-Za-z0-9]
  byte_class bcrypt_byte?, 0x03FFC00000000000_u64, 0x07FFFFFE07FFFFFE_u64
  # [\w+\-.] in ASCII
  byte_class email_local_byte?, 0x03FF680000000000_u64, 0x07FFFFFE87FFFFFE_u64
  # [\w.$] in ASCII
  byte_class table_reference_byte?, 0x03FF401000000000_u64, 0x07FFFFFE87FFFFFE_u64
  # [\w.-] in ASCII
  byte_class stdlib_segment_byte?, 0x03FF600000000000_u64, 0x07FFFFFE87FFFFFE_u64

  @[AlwaysInline]
  private def self.log_quote_byte?(byte : UInt8) : Bool
    byte === '"' || byte === '`'
  end

  # --- building blocks -------------------------------------------------------

  # The byte at *index*, or 0 outside the text. No class holds 0 and no
  # literal check compares with it, so the edge reads like `chars[index]?`
  # returning `nil`.
  @[AlwaysInline]
  private def self.byte_at(bytes : Bytes, index : Int32) : UInt8
    0 <= index < bytes.size ? bytes.unsafe_fetch(index) : 0_u8
  end

  # A string of ASCII *bytes*, with its character count already known.
  private def self.ascii_string(bytes : Bytes) : String
    String.new(bytes.size) do |buffer|
      buffer.copy_from(bytes.to_unsafe, bytes.size)
      {bytes.size, bytes.size}
    end
  end

  # One string made of the given byte runs, copied once.
  private def self.join_bytes(*parts : Bytes) : String
    total = parts.sum(&.size)
    String.new(total) do |buffer|
      offset = 0
      parts.each do |part|
        (buffer + offset).copy_from(part.to_unsafe, part.size)
        offset += part.size
      end
      {total, 0}
    end
  end

  # Whether the lowercase ASCII *keyword* starts at *index*, ignoring case as a
  # `/i` regex does (the callers' text holds no character that folds to an
  # ASCII letter).
  @[AlwaysInline]
  private def self.keyword_at?(bytes : Bytes, index : Int32, keyword : String) : Bool
    return false if index < 0 || index + keyword.bytesize > bytes.size
    letters = keyword.to_unsafe
    keyword.bytesize.times do |offset|
      byte = bytes.unsafe_fetch(index + offset)
      letter = letters[offset]
      return false unless byte == letter || ((byte | 0x20_u8) == letter && letter_byte?(letter))
    end
    true
  end

  # The end of `KEYWORD(\s+KEYWORD)*` at *index*, or `nil`.
  private def self.keyword_sequence_end(bytes : Bytes, index : Int32, keywords : Tuple) : Int32?
    position = index
    keywords.each_with_index do |keyword, number|
      if number > 0
        position = spaces_after(bytes, position) || return
      end
      return unless keyword_at?(bytes, position, keyword)
      position += keyword.bytesize
    end
    position
  end

  private def self.skip_spaces(bytes : Bytes, index : Int32) : Int32
    position = index
    while position < bytes.size && space_byte?(bytes.unsafe_fetch(position))
      position += 1
    end
    position
  end

  # The end of a `\s+` run at *index*, or `nil` when there is no white space.
  private def self.spaces_after(bytes : Bytes, index : Int32) : Int32?
    position = skip_spaces(bytes, index)
    position > index ? position : nil
  end

  # The start of the white space run that ends at *stop*.
  private def self.space_run_start(bytes : Bytes, stop : Int32) : Int32
    position = stop
    while position > 0 && space_byte?(bytes.unsafe_fetch(position - 1))
      position -= 1
    end
    position
  end

  @[AlwaysInline]
  private def self.boundary_before?(bytes : Bytes, index : Int32) : Bool
    word_byte?(byte_at(bytes, index - 1)) != word_byte?(byte_at(bytes, index))
  end

  # The end of the run of word bytes that starts at *index*.
  private def self.word_end(bytes : Bytes, index : Int32) : Int32
    position = index
    while position < bytes.size && word_byte?(bytes.unsafe_fetch(position))
      position += 1
    end
    position
  end

  # The end of `[A-Za-z_][A-Za-z0-9_]*` at *index* (*index* itself when none
  # starts there).
  private def self.ident_end(bytes : Bytes, index : Int32) : Int32
    first = byte_at(bytes, index)
    return index unless first === '_' || letter_byte?(first)
    word_end(bytes, index + 1)
  end

  private def self.digit_run_end(bytes : Bytes, index : Int32) : Int32
    position = index
    while position < bytes.size && digit_byte?(bytes.unsafe_fetch(position))
      position += 1
    end
    position
  end

  # Whether *bytes* are short enough that scanning them once costs less than
  # first looking for a letter the answer needs.
  @[AlwaysInline]
  private def self.short?(bytes : Bytes) : Bool
    bytes.size < 256
  end

  # Whether *bytes* hold the lowercase ASCII *letter* in either case.
  private def self.has_letter?(bytes : Bytes, letter : UInt8) : Bool
    !bytes.index(letter).nil? || !bytes.index(letter - 32).nil?
  end

  # Yields the start and end of every maximal run of word bytes. With
  # *skip_quoted*, every single-quoted literal and every double-quoted or
  # backtick identifier is passed over: a doubled delimiter inside the quotes
  # (`''`, `""`) stands for itself, and an unclosed quote runs to the end.
  private def self.each_word(bytes : Bytes, *, skip_quoted : Bool, &) : Nil
    kinds = WORD_SCAN_KINDS.to_unsafe
    pointer = bytes.to_unsafe
    size = bytes.size
    index = 0
    while index < size
      kind = kinds[pointer[index]]
      if kind == WORD_KIND
        stop = index + 1
        while stop < size && kinds[pointer[stop]] == WORD_KIND
          stop += 1
        end
        yield index, stop
        index = stop
      elsif kind == QUOTE_KIND && skip_quoted
        index = quoted_text_end(bytes, index, pointer[index])
      else
        index += 1
      end
    end
  end

  private WORD_KIND  = 1_u8
  private QUOTE_KIND = 2_u8

  # What each byte is to `.each_word`: a word byte (`[A-Za-z0-9_]`), a quote
  # that opens quoted text, or neither. A table lookup costs less than the
  # range checks in the scan's hottest loop.
  private WORD_SCAN_KINDS = begin
    kinds = StaticArray(UInt8, 256).new(0_u8)
    128.times do |byte|
      char = byte.unsafe_chr
      kinds[byte] = WORD_KIND if char.ascii_alphanumeric? || char == '_'
      kinds[byte] = QUOTE_KIND if char.in?('\'', '"', '`')
    end
    kinds
  end

  # The index after the quoted text that opens at *open* with *quote*.
  private def self.quoted_text_end(bytes : Bytes, open : Int32, quote : UInt8) : Int32
    position = open + 1
    while close = bytes.index(quote, position)
      return close + 1 unless byte_at(bytes, close + 1) == quote
      position = close + 2
    end
    bytes.size
  end

  # Whether a word in *bytes* begins `ORDER\s+BY`, `GROUP\s+BY`, or is
  # `LIMIT`, `OFFSET` (or, with *having*, `HAVING`) as a whole word. With
  # *skip_quoted*, quoted text is passed over as `.each_word` passes it.
  #
  # Every keyword starts with `o`, `l`, `g` or `h`, so only a byte that may be
  # one of those letters or a quote is looked at. The scan tests eight bytes at
  # a time for such bytes (see `.clause_candidates`) and checks each one it
  # finds against CLAUSE_SCAN_KINDS: a quote opens quoted text, and a keyword
  # letter is compared only where a word starts.
  private def self.clause_keyword_in?(bytes : Bytes, *, skip_quoted : Bool, having : Bool) : Bool
    kinds = CLAUSE_SCAN_KINDS.to_unsafe
    pointer = bytes.to_unsafe
    size = bytes.size
    wanted = skip_quoted ? CLAUSE_KEYWORD_START | CLAUSE_QUOTE : CLAUSE_KEYWORD_START
    index = 0
    while index < size
      candidates = clause_candidates(eight_bytes_at(pointer + index, Math.min(8, size &- index)))
      next_index = index &+ 8
      while candidates != 0
        position = index &+ candidates.trailing_zeros_count // 8
        candidates &= candidates &- 1
        kind = kinds[pointer[position]] & wanted
        next if kind == 0
        if kind == CLAUSE_QUOTE
          next_index = quoted_text_end(bytes, position, pointer[position])
          break
        end
        next if position > 0 && kinds[pointer[position &- 1]] & CLAUSE_WORD != 0
        return true if clause_keyword_at?(bytes, position, having: having)
      end
      index = next_index
    end
    false
  end

  # The *count* (at most eight) bytes at *pointer* as a little-endian word,
  # zero-filled past *count*.
  @[AlwaysInline]
  private def self.eight_bytes_at(pointer : Pointer(UInt8), count : Int32) : UInt64
    word = 0_u64
    # A constant count compiles to one unaligned load.
    if count == 8
      pointer.copy_to(pointerof(word).as(Pointer(UInt8)), 8)
    else
      pointer.copy_to(pointerof(word).as(Pointer(UInt8)), count)
    end
    {% if IO::ByteFormat::SystemEndian == IO::ByteFormat::BigEndian %}
      word = word.byte_swap
    {% end %}
    word
  end

  private EVERY_BYTE      = 0x0101010101010101_u64
  private LOW_SEVEN_BITS  = 0x7F7F7F7F7F7F7F7F_u64
  private HIGH_BIT        = 0x8080808080808080_u64
  private ASCII_LOWERCASE = 0x2020202020202020_u64

  # The high bit of every byte of *word* that is `g`, `h`, `l` or `o` in
  # either case, or `'`, `"` or a backtick. Setting bit 5 lowercases a letter;
  # it also maps a few control bytes and `@` onto a quote, which the caller's
  # table check rejects. A zero byte is never a candidate.
  @[AlwaysInline]
  private def self.clause_candidates(word : UInt64) : UInt64
    lowered = word | ASCII_LOWERCASE
    elsewhere = bytes_other_than(lowered, 'g') & bytes_other_than(lowered, 'h') &
                bytes_other_than(lowered, 'l') & bytes_other_than(lowered, 'o') &
                bytes_other_than(lowered, '\'') & bytes_other_than(lowered, '"') &
                bytes_other_than(lowered, '`')
    ~elsewhere & HIGH_BIT
  end

  # The high bit of every byte of *word* that differs from *char* (ASCII). A
  # byte of 0x80 or more always differs. Exact: no carry crosses bytes.
  @[AlwaysInline]
  private def self.bytes_other_than(word : UInt64, char : Char) : UInt64
    difference = word ^ (EVERY_BYTE &* char.ord.to_u64!)
    ((difference & LOW_SEVEN_BITS) &+ LOW_SEVEN_BITS) | difference
  end

  # Whether the word that starts at *start* begins `ORDER\s+BY`, `GROUP\s+BY`,
  # or is `LIMIT`, `OFFSET` (or, with *having*, `HAVING`).
  private def self.clause_keyword_at?(bytes : Bytes, start : Int32, *, having : Bool) : Bool
    case bytes.unsafe_fetch(start) | 0x20_u8
    when 'o' then by_keyword_at?(bytes, start, "order") || whole_keyword_at?(bytes, start, "offset")
    when 'l' then whole_keyword_at?(bytes, start, "limit")
    when 'g' then by_keyword_at?(bytes, start, "group")
    when 'h' then having && whole_keyword_at?(bytes, start, "having")
    else          false
    end
  end

  # Whether *keyword* is the whole word at *start*.
  private def self.whole_keyword_at?(bytes : Bytes, start : Int32, keyword : String) : Bool
    keyword_at?(bytes, start, keyword) && !word_byte?(byte_at(bytes, start + keyword.bytesize))
  end

  # Whether the five-letter *keyword* is the word at *start* and `\s+BY\b`
  # follows it.
  private def self.by_keyword_at?(bytes : Bytes, start : Int32, keyword : String) : Bool
    return false unless keyword_at?(bytes, start, keyword)
    after = spaces_after(bytes, start + keyword.bytesize) || return false
    keyword_at?(bytes, after, "by") && !word_byte?(byte_at(bytes, after + 2))
  end

  private CLAUSE_WORD          = 1_u8
  private CLAUSE_KEYWORD_START = 2_u8
  private CLAUSE_QUOTE         = 4_u8

  # What each byte is to `.clause_keyword_in?`: a word byte (`[A-Za-z0-9_]`),
  # which is also a keyword start when it is `o`, `l`, `g` or `h` in either
  # case, or a quote that opens quoted text.
  private CLAUSE_SCAN_KINDS = begin
    kinds = StaticArray(UInt8, 256).new(0_u8)
    128.times do |byte|
      char = byte.unsafe_chr
      kinds[byte] = CLAUSE_WORD if char.ascii_alphanumeric? || char == '_'
      kinds[byte] |= CLAUSE_KEYWORD_START if char.downcase.in?('o', 'l', 'g', 'h')
      kinds[byte] = CLAUSE_QUOTE if char.in?('\'', '"', '`')
    end
    kinds
  end

  private def self.statement_keyword?(bytes : Bytes, start : Int32, stop : Int32) : Bool
    case stop - start
    when 4 then keyword_at?(bytes, start, "from") || keyword_at?(bytes, start, "into")
    when 6 then keyword_at?(bytes, start, "update")
    else        false
    end
  end

  # The end of `ONLY\s+` at *index*, or `nil`.
  private def self.only_keyword_end(bytes : Bytes, index : Int32) : Int32?
    return unless keyword_at?(bytes, index, "only")
    spaces_after(bytes, index + 4)
  end

  # `[`"\[]?([\w.$]+)` at *index*: the reference without its opening quote.
  private def self.table_reference_at(bytes : Bytes, index : Int32) : String?
    opening = byte_at(bytes, index)
    start = opening === '`' || opening === '"' || opening === '[' ? index + 1 : index
    stop = start
    while stop < bytes.size && table_reference_byte?(bytes.unsafe_fetch(stop))
      stop += 1
    end
    stop > start ? ascii_string(bytes[start, stop - start]) : nil
  end

  # Whether `/src` starts at *index* (the caller checked the `/` after it).
  private def self.src_directory_at?(bytes : Bytes, index : Int32) : Bool
    bytes.unsafe_fetch(index) === '/' && bytes.unsafe_fetch(index + 1) === 's' &&
      bytes.unsafe_fetch(index + 2) === 'r' && bytes.unsafe_fetch(index + 3) === 'c'
  end

  # Whether the directory that ends at the `/` at *slash* (the one before
  # `src/`) is `/crystal`, or a `[\w.-]*` name holding `crystal` right after
  # `/share/`.
  private def self.stdlib_directory_before?(bytes : Bytes, slash : Int32) : Bool
    start = slash
    while start > 0 && stdlib_segment_byte?(bytes.unsafe_fetch(start - 1))
      start -= 1
    end
    return false unless start > 0 && bytes.unsafe_fetch(start - 1) === '/'
    directory = bytes[start, slash - start]
    return true if directory == "crystal".to_slice
    start >= 7 && bytes[start - 7, 6] == "/share".to_slice && holds_crystal?(directory)
  end

  private def self.holds_crystal?(bytes : Bytes) : Bool
    name = "crystal".to_slice
    (0..bytes.size - name.size).any? { |index| bytes[index, name.size] == name }
  end

  # The end of `REF` (see `.column_function?`) at *index*, or `nil`.
  private def self.column_reference_end(bytes : Bytes, index : Int32) : Int32?
    first_end = ident_end(bytes, index)
    return if first_end == index
    if byte_at(bytes, first_end) === '.'
      second_end = ident_end(bytes, first_end + 1)
      return second_end if second_end > first_end + 1
    end
    first_end
  end

  # Matches `(?:\s+(asc|desc))?(?:\s+nulls\s+(first|last))?\s*\z` (ignoring
  # case) at *index*: the start and end of the direction and of the NULL
  # placement (-1 when absent), or `nil` when the rest of the text has another
  # shape.
  private def self.sort_tail(bytes : Bytes, index : Int32) : {Int32, Int32, Int32, Int32}?
    position = index
    direction_start = direction_stop = -1
    if start = spaces_after(bytes, position)
      if word = {"asc", "desc"}.find { |candidate| keyword_at?(bytes, start, candidate) }
        direction_start = start
        direction_stop = position = start + word.bytesize
      end
    end
    nulls_start = nulls_stop = -1
    if (start = spaces_after(bytes, position)) && keyword_at?(bytes, start, "nulls") && (placement_start = spaces_after(bytes, start + 5))
      if word = {"first", "last"}.find { |candidate| keyword_at?(bytes, placement_start, candidate) }
        nulls_start = placement_start
        nulls_stop = position = placement_start + word.bytesize
      end
    end
    skip_spaces(bytes, position) == bytes.size ? {direction_start, direction_stop, nulls_start, nulls_stop} : nil
  end

  # The start of one of *keywords* that ends exactly at *stop*, or `nil`.
  private def self.trailing_keyword_start(bytes : Bytes, stop : Int32, keywords : Tuple) : Int32?
    keywords.each do |keyword|
      start = stop - keyword.bytesize
      return start if keyword_at?(bytes, start, keyword)
    end
    nil
  end

  # When `KEYWORD\s+` ends at *index*, the start of the white space before
  # KEYWORD, provided there is some; otherwise `nil`.
  private def self.keyword_before_spaces(bytes : Bytes, index : Int32, keyword : String) : Int32?
    run_start = space_run_start(bytes, index)
    return if run_start == index
    keyword_start = run_start - keyword.bytesize
    return unless keyword_at?(bytes, keyword_start, keyword)
    return unless keyword_start > 0 && space_byte?(bytes.unsafe_fetch(keyword_start - 1))
    keyword_start
  end

  # Matches `\A\$2[abxy]?\$\d{2}\$`, the prefix of a bcrypt hash: where the
  # hash body starts, or `nil`.
  private def self.bcrypt_body_start(bytes : Bytes) : Int32?
    return unless byte_at(bytes, 0) === '$' && byte_at(bytes, 1) === '2'
    index = 2
    version = byte_at(bytes, index)
    index += 1 if version === 'a' || version === 'b' || version === 'x' || version === 'y'
    return unless byte_at(bytes, index) === '$'
    return unless digit_byte?(byte_at(bytes, index + 1)) && digit_byte?(byte_at(bytes, index + 2))
    return unless byte_at(bytes, index + 3) === '$'
    index + 4
  end

  # Matches `"?([A-Za-z_][A-Za-z0-9_]*)"?\.(?=["A-Za-z_])` at *index*: the
  # start and end of the qualifier name and the index of its dot, or `nil`.
  private def self.qualifier_at(bytes : Bytes, index : Int32) : {Int32, Int32, Int32}?
    name_start = bytes.unsafe_fetch(index) === '"' ? index + 1 : index
    name_end = ident_end(bytes, name_start)
    return if name_end == name_start
    dot = byte_at(bytes, name_end) === '"' ? name_end + 1 : name_end
    following = byte_at(bytes, dot + 1)
    return unless byte_at(bytes, dot) === '.'
    return unless following === '"' || following === '_' || letter_byte?(following)
    {name_start, name_end, dot}
  end

  # The end of a URL scheme `[A-Za-z][A-Za-z0-9+.\-]*` at the start, or `nil`.
  private def self.scheme_end(bytes : Bytes) : Int32?
    return unless letter_byte?(byte_at(bytes, 0))
    position = 1
    while position < bytes.size && scheme_byte?(bytes.unsafe_fetch(position))
      position += 1
    end
    position
  end

  # `'(?:[^'\\]|''|\\.)*'` as the whole text.
  private def self.quoted_mysql_string?(bytes : Bytes) : Bool
    return false unless bytes.size >= 2 && bytes.unsafe_fetch(0) === '\'' && bytes.unsafe_fetch(bytes.size - 1) === '\''
    index = 1
    stop = bytes.size - 1
    while index < stop
      byte = bytes.unsafe_fetch(index)
      if byte === '\''
        return false unless index + 1 < stop && bytes.unsafe_fetch(index + 1) === '\''
        index += 2
      elsif byte === '\\'
        return false if index + 1 >= stop || bytes.unsafe_fetch(index + 1) === '\n'
        index += 2
      else
        index += 1
      end
    end
    true
  end

  # `\b\d+\b` replaced by `?`.
  private def self.replace_standalone_numbers(text : String) : String
    bytes = text.to_slice
    index = 0
    while index < bytes.size && !digit_byte?(bytes.unsafe_fetch(index))
      index += 1
    end
    return text if index == bytes.size
    single_byte_string(bytes.size) do |io|
      copied = 0
      while index < bytes.size
        unless digit_byte?(bytes.unsafe_fetch(index))
          index += 1
          next
        end
        run_end = digit_run_end(bytes, index)
        if !word_byte?(byte_at(bytes, index - 1)) && !word_byte?(byte_at(bytes, run_end))
          io.write(bytes[copied, index - copied])
          io << '?'
          copied = run_end
        end
        index = run_end
      end
      io.write(bytes[copied..])
    end
  end

  # `'[^']*'` replaced by `?`.
  private def self.replace_quoted_strings(text : String) : String
    bytes = text.to_slice
    open = bytes.index('\''.ord.to_u8) || return text
    single_byte_string(bytes.size) do |io|
      copied = 0
      while open && (close = bytes.index('\''.ord.to_u8, open + 1))
        io.write(bytes[copied, open - copied])
        io << '?'
        copied = close + 1
        open = bytes.index('\''.ord.to_u8, copied)
      end
      io.write(bytes[copied..])
    end
  end

  # `\s+` replaced by one space.
  private def self.collapse_spaces(text : String) : String
    bytes = text.to_slice
    index = 0
    # Text whose white space is all single spaces stays as it is.
    while index < bytes.size
      byte = bytes.unsafe_fetch(index)
      break if space_byte?(byte) && (byte != 0x20 || space_byte?(byte_at(bytes, index + 1)))
      index += 1
    end
    return text if index == bytes.size
    single_byte_string(bytes.size) do |io|
      copied = 0
      while index < bytes.size
        unless space_byte?(bytes.unsafe_fetch(index))
          index += 1
          next
        end
        run_end = skip_spaces(bytes, index)
        io.write(bytes[copied, index - copied])
        io << ' '
        copied = index = run_end
      end
      io.write(bytes[copied..])
    end
  end

  # Builds a string from single-byte text, which keeps its character count
  # equal to its byte size.
  private def self.single_byte_string(capacity : Int32, & : IO ->) : String
    built = String.build(capacity) { |io| yield io }
    String.new(built.bytesize) do |buffer|
      buffer.copy_from(built.to_unsafe, built.bytesize)
      {built.bytesize, built.bytesize}
    end
  end

  # The alias part of a raw JOIN after its table name, as `{start, end}`.
  private def self.join_alias_range(bytes : Bytes, table_end : Int32) : {Int32, Int32}?
    start = spaces_after(bytes, table_end) || return
    if keyword_at?(bytes, start, "as") && (after_as = spaces_after(bytes, start + 2))
      if join_alias_allowed?(bytes, after_as)
        stop = ident_end(bytes, after_as)
        return {after_as, stop} if stop > after_as
      end
    end
    return unless join_alias_allowed?(bytes, start)
    stop = ident_end(bytes, start)
    stop > start ? {start, stop} : nil
  end

  private def self.join_alias_allowed?(bytes : Bytes, index : Int32) : Bool
    {"on", "using", "inner", "left", "right", "full", "cross", "natural", "join"}.none? do |keyword|
      keyword_at?(bytes, index, keyword) && boundary_before?(bytes, index + keyword.bytesize)
    end
  end

  # `["`]?\s*(?:=|!=|<>|<=|>=|<|>|\bLIKE|\bILIKE)\s*(\?|\$\d+)` after a name.
  private def self.comparison_placeholder(bytes : Bytes, name_end : Int32) : Placeholder?
    position = log_quote_byte?(byte_at(bytes, name_end)) ? name_end + 1 : name_end
    operator_start = skip_spaces(bytes, position)
    first = byte_at(bytes, operator_start)
    second = byte_at(bytes, operator_start + 1)
    # The operators in the order the alternation tries them.
    {"=", "!=", "<>", "<=", ">=", "<", ">"}.each do |operator|
      next unless first == operator.to_unsafe[0] && (operator.bytesize == 1 || second == operator.to_unsafe[1])
      if placeholder = placeholder_at(bytes, skip_spaces(bytes, operator_start + operator.bytesize))
        return placeholder
      end
    end
    return unless boundary_before?(bytes, operator_start)
    {"like", "ilike"}.each do |operator|
      if keyword_at?(bytes, operator_start, operator)
        if placeholder = placeholder_at(bytes, skip_spaces(bytes, operator_start + operator.bytesize))
          return placeholder
        end
      end
    end
    nil
  end

  # `\?|\$\d+` exactly at *index*.
  private def self.placeholder_at(bytes : Bytes, index : Int32) : Placeholder?
    byte = byte_at(bytes, index)
    if byte === '?'
      Placeholder.new("?", index)
    elsif byte === '$'
      digits_end = digit_run_end(bytes, index + 1)
      digits_end > index + 1 ? Placeholder.new(ascii_string(bytes[index, digits_end - index]), index) : nil
    end
  end

  # Every `\?|\$\d+` in `bytes[start...stop]`.
  private def self.placeholders_in(bytes : Bytes, start : Int32, stop : Int32) : Array(Placeholder)
    found = [] of Placeholder
    index = start
    while index < stop
      byte = bytes.unsafe_fetch(index)
      if byte === '?'
        found << Placeholder.new("?", index)
        index += 1
      elsif byte === '$' && (digits_end = Math.min(digit_run_end(bytes, index + 1), stop)) > index + 1
        found << Placeholder.new(ascii_string(bytes[index, digits_end - index]), index)
        index = digits_end
      else
        index += 1
      end
    end
    found
  end

  # `\s*\(([^)]*)\)\s*VALUES\s*(.*)` after the `\S+` target of an INSERT that
  # runs from *target_start* to *target_end*: `\S+` gives back characters from
  # its end until `\s*\(` can follow.
  private def self.insert_binds_after_target(bytes : Bytes, closes : CloseParenFinder, target_start : Int32, target_end : Int32) : InsertBinds?
    target_end.downto(target_start + 1) do |candidate|
      open = candidate == target_end ? skip_spaces(bytes, candidate) : candidate
      next unless byte_at(bytes, open) === '('
      close = closes.at_or_after(open + 1) || next
      values = skip_spaces(bytes, close + 1)
      next unless keyword_at?(bytes, values, "values")
      rest = skip_spaces(bytes, values + 6)
      return InsertBinds.new(String.new(bytes[open + 1, close - open - 1]), placeholders_in(bytes, rest, bytes.size))
    end
    nil
  end

  # `["`]?\s+(?:NOT\s+)?IN\s*\(([^)]*)\)` after a name: the range inside the
  # parentheses.
  private def self.in_list_range(bytes : Bytes, closes : CloseParenFinder, name_end : Int32) : {Int32, Int32}?
    position = log_quote_byte?(byte_at(bytes, name_end)) ? name_end + 1 : name_end
    start = spaces_after(bytes, position) || return
    if keyword_at?(bytes, start, "not") && (after_not = spaces_after(bytes, start + 3))
      if range = in_parentheses(bytes, closes, after_not)
        return range
      end
    end
    in_parentheses(bytes, closes, start)
  end

  private def self.in_parentheses(bytes : Bytes, closes : CloseParenFinder, index : Int32) : {Int32, Int32}?
    return unless keyword_at?(bytes, index, "in")
    open = skip_spaces(bytes, index + 2)
    return unless byte_at(bytes, open) === '('
    close = closes.at_or_after(open + 1) || return
    {open + 1, close}
  end

  # The domain of an address from *start*: labels of `[a-z\d\-]` joined by
  # dots, the last one letters only, at least two labels, none empty.
  private def self.email_domain?(bytes : Bytes, start : Int32) : Bool
    label_start = start
    letters_only = true
    labels = 1
    index = label_start
    while index < bytes.size
      byte = bytes.unsafe_fetch(index)
      if byte === '.'
        return false if index == label_start
        labels += 1
        label_start = index + 1
        letters_only = true
      elsif letter_byte?(byte)
        # still a possible last label
      elsif digit_byte?(byte) || byte === '-'
        letters_only = false
      else
        return false
      end
      index += 1
    end
    labels >= 2 && label_start < bytes.size && letters_only
  end

  # `[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b` from *start*, in text
  # whose bytes from *start* on are all URL path bytes, so whatever follows the
  # top-level domain completes the match.
  private def self.url_host_and_tld?(bytes : Bytes, start : Int32) : Bool
    host_run = start
    while host_run < bytes.size && url_host_byte?(bytes.unsafe_fetch(host_run))
      host_run += 1
    end
    last_dot = Math.min(host_run, start + 256)
    (start + 1..last_dot).each do |dot|
      next unless byte_at(bytes, dot) === '.'
      (1..6).each do |length|
        stop = dot + 1 + length
        break if stop > bytes.size || !url_tld_byte?(bytes.unsafe_fetch(stop - 1))
        return true if word_byte?(bytes.unsafe_fetch(stop - 1)) != word_byte?(byte_at(bytes, stop))
      end
    end
    false
  end

  # Finds the next byte that is a lowercase ASCII letter or its uppercase
  # form, with one `memchr` per case: each case's next position is kept until
  # the scan passes it, so a whole scan reads the text at most twice.
  private struct LetterFinder
    @position = 0
    @next_lower = -1
    @next_upper = -1

    def initialize(@bytes : Bytes, @lower : UInt8)
      @upper = @lower.unsafe_chr.ascii_lowercase? ? @lower - 32 : @lower
    end

    # Moves the scan to *position*.
    def advance(@position : Int32) : Nil
    end

    # The first index at or after the scan position that holds the letter.
    def next_at : Int32?
      @next_lower = @bytes.index(@lower, @position) || @bytes.size if @next_lower < @position
      @next_upper = @bytes.index(@upper, @position) || @bytes.size if @next_upper < @position
      found = Math.min(@next_lower, @next_upper)
      found < @bytes.size ? found : nil
    end
  end

  # Answers "the first `)` at or after *index*", as a table built from the
  # right would, with `memchr` over only the bytes no earlier question
  # covered. Questions may move forward or back; each byte is read a bounded
  # number of times. A class, so the helpers it is passed to share what it
  # has learned.
  private class CloseParenFinder
    # The answer for `@from` and every index up to it: no `)` lies in
    # `@from...@found`, and `@found` (or the end, -1) holds one.
    @from = Int32::MAX
    @found = -1

    def initialize(@bytes : Bytes)
    end

    def at_or_after(index : Int32) : Int32?
      return if index >= @bytes.size
      if index >= @from && (@found < 0 || index <= @found)
        # Already covered.
      elsif index < @from && index < @bytes.size && @from != Int32::MAX
        if earlier = @bytes[index, @from - index].index(')'.ord.to_u8)
          @found = index + earlier
        end
        @from = index
      else
        @from = index
        @found = @bytes.index(')'.ord.to_u8, index) || -1
      end
      @found < 0 ? nil : @found
    end
  end
end
