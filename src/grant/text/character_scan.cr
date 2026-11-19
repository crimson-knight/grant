require "./character_class"

# :nodoc:
#
# The general form of every `Grant::TextMatching` method: it reads the text
# as an `Array(Char)`, so it answers any UTF-8 text with the Unicode classes
# and case folds a Crystal `Regex` uses. `Grant::TextMatching` calls it for
# text that holds a multibyte character and answers single-byte text by
# scanning its bytes. Indices are character indices, as
# `Regex::MatchData#begin` reports them.
module Grant::TextMatching::CharacterScan
  # Replaces `/\A[A-Za-z_][A-Za-z0-9_]*\z/`: a bare SQL identifier.
  def self.simple_identifier?(text : String) : Bool
    return false if text.empty?
    text.each_char_with_index do |char, index|
      return false unless identifier_char?(char, first: index == 0)
    end
    true
  end

  # Replaces `/\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?\z/`: a
  # column name or a `table.column` pair.
  def self.qualified_identifier?(text : String) : Bool
    part_start = true
    dots = 0
    text.each_char do |char|
      if char == '.'
        return false if part_start || dots == 1
        dots += 1
        part_start = true
      else
        return false unless identifier_char?(char, first: part_start)
        part_start = false
      end
    end
    !part_start
  end

  # Replaces `/\A[A-Za-z][A-Za-z0-9_., ]*\z/`: the characters a vendor lock
  # clause may hold.
  def self.lock_clause?(text : String) : Bool
    chars = text.chars
    return false if chars.empty? || !chars[0].ascii_letter?
    chars.each(within: 1..) do |char|
      return false unless char.ascii_alphanumeric? || char.in?('_', '.', ',', ' ')
    end
    true
  end

  # Replaces the group of `/\A([A-Za-z][A-Za-z0-9+.\-]*):/`: the scheme of a
  # URL as written, or `nil` when it has none.
  def self.url_scheme(url : String) : String?
    chars = url.chars
    scheme_end = scheme_end(chars)
    return unless scheme_end && chars[scheme_end]? == ':'
    url[0, scheme_end]
  end

  # Replaces `url.sub(/\A([A-Za-z][A-Za-z0-9+.\-]*:\/\/)[^?#]*@/, "\\1***@")`:
  # hides the user information of a URL, up to its last `@` before any query
  # or fragment.
  def self.redact_url_credentials(url : String) : String
    chars = url.chars
    scheme_end = scheme_end(chars) || return url
    return url unless chars[scheme_end]? == ':' && chars[scheme_end + 1]? == '/' && chars[scheme_end + 2]? == '/'
    authority_start = scheme_end + 3
    last_at = nil
    index = authority_start
    while index < chars.size && !chars[index].in?('?', '#')
      last_at = index if chars[index] == '@'
      index += 1
    end
    return url unless last_at
    String.build do |io|
      chars.each(within: 0...authority_start) { |char| io << char }
      io << "***@"
      chars.each(within: (last_at + 1)..) { |char| io << char }
    end
  end

  # Replaces `url.sub(/\Asqlite3?:(?:\/\/)?/, "")`: a SQLite URL without its
  # scheme and the optional `//`.
  def self.strip_sqlite_scheme(url : String) : String
    rest = if url.starts_with?("sqlite3:")
             url[8..]
           elsif url.starts_with?("sqlite:")
             url[7..]
           else
             return url
           end
    rest.starts_with?("//") ? rest[2..] : rest
  end

  # Replaces `url.sub(/\Apostgres(ql)?:/, replacement)`.
  def self.replace_postgres_scheme(url : String, replacement : String) : String
    if url.starts_with?("postgresql:")
      replacement + url[11..]
    elsif url.starts_with?("postgres:")
      replacement + url[9..]
    else
      url
    end
  end

  # Replaces `url.matches?(/[?&]encoding=/i)`.
  def self.encoding_option?(url : String) : Bool
    chars = url.chars
    chars.each_with_index do |char, index|
      return true if char.in?('?', '&') && keyword_at?(chars, index + 1, "encoding") && chars[index + 9]? == '='
    end
    false
  end

  # Replaces `piece.sub(/\s+(?:ASC|DESC)\z/i, "")`: an index column without its
  # trailing sort direction.
  def self.strip_trailing_sort_direction(piece : String) : String
    chars = piece.chars
    word_start = if keyword_at?(chars, chars.size - 3, "asc")
                   chars.size - 3
                 elsif keyword_at?(chars, chars.size - 4, "desc")
                   chars.size - 4
                 end
    return piece unless word_start && word_start > 0 && CC.space?(chars[word_start - 1])
    run_start = word_start - 1
    while run_start > 0 && CC.space?(chars[run_start - 1])
      run_start -= 1
    end
    piece[0, run_start]
  end

  # Replaces `text.gsub(/\$\d+/) { |match| ... }`: yields each `$<digits>`
  # placeholder and puts the block's result in its place.
  def self.replace_numbered_placeholders(text : String, & : String -> String) : String
    return text unless text.includes?('$')
    chars = text.chars
    String.build do |io|
      index = 0
      while index < chars.size
        char = chars[index]
        digits_end = char == '$' ? digit_run_end(chars, index + 1) : index + 1
        if char == '$' && digits_end > index + 1
          io << yield text_of(chars, index, digits_end)
          index = digits_end
        else
          io << char
          index += 1
        end
      end
    end
  end

  # Replaces `text.gsub(/(?<![\w."`])#{Regex.escape(table)}\./, replacement)`:
  # rewrites `table.` qualifiers that are not part of a longer name. The
  # *replacement* is written as given (`gsub` with a string would expand `\0`
  # and the like); callers pass identifiers or quoted table names, which hold
  # no backslashes.
  def self.replace_table_qualifier(text : String, table : String, replacement : String) : String
    needle = "#{table}."
    return text unless text.includes?(needle)
    chars = text.chars
    needle_chars = needle.chars
    String.build do |io|
      index = 0
      while index < chars.size
        previous = index > 0 ? chars[index - 1] : nil
        if (previous.nil? || !(CC.word?(previous) || previous.in?('.', '"', '`'))) && chars_at?(chars, index, needle_chars)
          io << replacement
          index += needle_chars.size
        else
          io << chars[index]
          index += 1
        end
      end
    end
  end

  # Replaces `query.split(/([a-zA-Z0-9_$']+)/)`: the text between runs of
  # word characters and the runs themselves, alternating, starting and ending
  # with a (possibly empty) gap, as `String#split` with a capture group yields.
  def self.split_sql_words(query : String) : Array(String)
    return [""] if query.empty?
    chars = query.chars
    parts = [] of String
    gap_start = 0
    index = 0
    while index < chars.size
      if sql_word_char?(chars[index])
        run_end = index
        while run_end < chars.size && sql_word_char?(chars[run_end])
          run_end += 1
        end
        parts << text_of(chars, gap_start, index)
        parts << text_of(chars, index, run_end)
        gap_start = index = run_end
      else
        index += 1
      end
    end
    parts << text_of(chars, gap_start, chars.size)
    parts
  end

  # Replaces `word =~ /\d+/`: whether *text* holds a decimal digit. Kept out
  # of line: inlined, this Unicode path would grow the single-byte
  # `TextMatching.contains_digit?` that calls it.
  @[NoInline]
  def self.contains_digit?(text : String) : Bool
    text.each_char.any? { |char| CC.digit?(char) }
  end

  # Replaces `text =~ /KEYWORD/i` for an ASCII *keyword*: whether *text*
  # contains it, ignoring case.
  def self.contains_ignoring_case?(text : String, keyword : String) : Bool
    chars = text.chars
    (0..chars.size - keyword.size).any? { |index| keyword_at?(chars, index, keyword) }
  end

  # Replaces the chain
  # `sql.gsub(/\b\d+\b/, "?").gsub(/'[^']*'/, "?").gsub(/\$\d+/, "?").gsub(/\s+/, " ")`:
  # a statement with its literals and placeholders replaced, for grouping
  # statements of the same shape.
  def self.normalize_sql_shape(sql : String) : String
    shape = replace_standalone_numbers(sql)
    shape = replace_quoted_strings(shape)
    shape = replace_numbered_placeholders(shape) { "?" }
    collapse_spaces(shape)
  end

  # Replaces `/\bfor\s+(update|share|no\s+key\s+update|key\s+share)\b/i`: a
  # read that takes row locks.
  def self.locking_read?(sql : String) : Bool
    chars = sql.chars
    chars.each_index do |index|
      next unless keyword_at?(chars, index, "for") && boundary_before?(chars, index)
      start = spaces_after(chars, index + 3) || next
      return true if keyword_sequence_end(chars, start, {"update"}).try { |stop| boundary_before?(chars, stop) }
      return true if keyword_sequence_end(chars, start, {"share"}).try { |stop| boundary_before?(chars, stop) }
      return true if keyword_sequence_end(chars, start, {"no", "key", "update"}).try { |stop| boundary_before?(chars, stop) }
      return true if keyword_sequence_end(chars, start, {"key", "share"}).try { |stop| boundary_before?(chars, stop) }
    end
    false
  end

  # Replaces `/\b(ORDER\s+BY|LIMIT|OFFSET|GROUP\s+BY)\b/i`: whether a raw
  # clause holds SQL that does not belong in a WHERE condition.
  def self.trailing_clause_keyword?(clause : String) : Bool
    trailing_clause_keyword_in?(clause.chars)
  end

  # Whether a raw clause holds SQL that follows a WHERE condition: the
  # `.trailing_clause_keyword?` words or `HAVING`, each a whole word in any
  # case. Text inside single-quoted literals and double-quoted or backtick
  # identifiers is skipped, so `WHERE title = 'LIMIT'` is a plain condition.
  def self.sql_after_condition?(clause : String) : Bool
    chars = mask_quoted_text(clause.chars)
    trailing_clause_keyword_in?(chars) || whole_keyword?(chars, "having")
  end

  # Whether a raw clause joins another table: the word `JOIN` in any case,
  # outside quoted literals and identifiers.
  def self.join_clause?(clause : String) : Bool
    whole_keyword?(mask_quoted_text(clause.chars), "join")
  end

  # Replaces `type.sub(/\ATIMESTAMP(\(\d+\))?/i, replacement)`: a column type
  # whose leading `TIMESTAMP` (and its precision) is rewritten.
  def self.replace_leading_timestamp(type : String, replacement : String) : String
    chars = type.chars
    return type unless keyword_at?(chars, 0, "timestamp")
    stop = 9
    if chars[stop]? == '('
      digits_end = digit_run_end(chars, stop + 1)
      stop = digits_end + 1 if digits_end > stop + 1 && chars[digits_end]? == ')'
    end
    replacement + text_of(chars, stop, chars.size)
  end

  # Replaces `/\A(?:'(?:[^'\\]|''|\\.)*'|[-+]?\d+(?:\.\d+)?)\z/`: a MySQL
  # default that is a quoted string or a signed decimal number.
  def self.mysql_literal_default?(text : String) : Bool
    chars = text.chars
    return quoted_mysql_string?(chars) if chars.first? == '\''
    index = chars.first?.try(&.in?('-', '+')) ? 1 : 0
    integer_end = digit_run_end(chars, index)
    return false if integer_end == index
    return true if integer_end == chars.size
    return false unless chars[integer_end] == '.'
    fraction_end = digit_run_end(chars, integer_end + 1)
    fraction_end > integer_end + 1 && fraction_end == chars.size
  end

  # Replaces `/\A(CURRENT_TIMESTAMP|CURRENT_DATE|CURRENT_TIME|NOW|LOCALTIMESTAMP|LOCALTIME)(\(\d*\))?\z/i`
  # (with *mysql*) and `/\ACURRENT_(TIMESTAMP|DATE|TIME)\z/i`: a time keyword
  # that is a column default as written.
  def self.bare_time_default?(text : String, *, mysql : Bool) : Bool
    chars = text.chars
    unless mysql
      return {"current_timestamp", "current_date", "current_time"}.any? { |keyword| keyword.size == chars.size && keyword_at?(chars, 0, keyword) }
    end
    {"current_timestamp", "current_date", "current_time", "now", "localtimestamp", "localtime"}.any? do |keyword|
      next false unless keyword_at?(chars, 0, keyword)
      stop = keyword.size
      next true if stop == chars.size
      next false unless chars[stop] == '('
      digits_end = digit_run_end(chars, stop + 1)
      chars[digits_end]? == ')' && digits_end + 1 == chars.size
    end
  end

  # Replaces the group of `/\A(?:DATETIME|TIMESTAMP|TIME)\((\d+)\)/i`: the
  # fractional digits of a time column type.
  def self.time_type_precision(type : String) : String?
    chars = type.chars
    {"datetime", "timestamp", "time"}.each do |keyword|
      next unless keyword_at?(chars, 0, keyword) && chars[keyword.size]? == '('
      digits_end = digit_run_end(chars, keyword.size + 1)
      return text_of(chars, keyword.size + 1, digits_end) if digits_end > keyword.size + 1 && chars[digits_end]? == ')'
    end
    nil
  end

  # Replaces `/\A(CURRENT_TIMESTAMP|CURRENT_TIME|NOW|LOCALTIMESTAMP|LOCALTIME)\z/i`.
  def self.current_time_keyword?(text : String) : Bool
    chars = text.chars
    {"current_timestamp", "current_time", "now", "localtimestamp", "localtime"}.any? do |keyword|
      keyword.size == chars.size && keyword_at?(chars, 0, keyword)
    end
  end

  # Replaces `text.sub(/\(\d+\)/, "")`: drops the first parenthesized number.
  def self.remove_parenthesized_number(text : String) : String
    chars = text.chars
    chars.each_with_index do |char, index|
      next unless char == '('
      digits_end = digit_run_end(chars, index + 1)
      if digits_end > index + 1 && chars[digits_end]? == ')'
        return text_of(chars, 0, index) + text_of(chars, digits_end + 1, chars.size)
      end
    end
    text
  end

  # Replaces `name.sub(/\s*\(.*\)/, "")`: drops the first parenthesized part
  # (with the white space before it) up to the last `)` on that line.
  def self.remove_parenthesized_suffix(name : String) : String
    chars = name.chars
    # For each index, the last `)` at or after it on the same line (`.` stops
    # at a newline), found in one pass from the right.
    last_close = Array(Int32?).new(chars.size + 1, nil)
    (chars.size - 1).downto(0) do |index|
      last_close[index] = case chars[index]
                          when '\n' then nil
                          when ')'  then last_close[index + 1] || index
                          else           last_close[index + 1]
                          end
    end
    chars.each_with_index do |char, index|
      next unless char == '('
      close = last_close[index + 1] || next
      start = index
      while start > 0 && CC.space?(chars[start - 1])
        start -= 1
      end
      return text_of(chars, 0, start) + text_of(chars, close + 1, chars.size)
    end
    name
  end

  # Replaces `clause.sub(/\AWHERE\s+/i, "")`.
  def self.strip_leading_where(clause : String) : String
    chars = clause.chars
    return clause unless keyword_at?(chars, 0, "where")
    rest = spaces_after(chars, 5) || return clause
    text_of(chars, rest, chars.size)
  end

  # Replaces the first group of
  # `/\b(?:FROM|INTO|UPDATE)\s+(?:ONLY\s+)?[`"\[]?([\w.$]+)/i`: the table a
  # statement reads or writes, as written.
  def self.statement_table(sql : String) : String?
    chars = sql.chars
    chars.each_index do |index|
      next unless boundary_before?(chars, index)
      keyword = {"from", "into", "update"}.find { |candidate| keyword_at?(chars, index, candidate) } || next
      start = spaces_after(chars, index + keyword.size) || next
      if keyword_at?(chars, start, "only") && (after_only = spaces_after(chars, start + 4))
        if table = table_reference_at(chars, after_only)
          return table
        end
      end
      if table = table_reference_at(chars, start)
        return table
      end
    end
    nil
  end

  # Replaces `/\A(.+?:\d+(?::\d+)?)(.*)\z/m` (whose two groups rebuild the
  # frame): whether a backtrace frame carries a `:line` after its first
  # character.
  def self.frame_with_line?(frame : String) : Bool
    chars = frame.chars
    (1...chars.size - 1).any? { |index| chars[index] == ':' && CC.digit?(chars[index + 1]) }
  end

  # Replaces `%r{/(?:share/[\w.-]*crystal[\w.-]*|crystal)/src/}`: whether a
  # path lies in the Crystal standard library.
  def self.stdlib_path?(path : String) : Bool
    return true if path.includes?("/crystal/src/")
    chars = path.chars
    share = "/share/".chars
    index = 0
    while index < chars.size
      if chars_at?(chars, index, share)
        run_start = index + share.size
        run_end = run_start
        while run_end < chars.size && (CC.word?(chars[run_end]) || chars[run_end].in?('.', '-'))
          run_end += 1
        end
        if chars_at?(chars, run_end, "/src/".chars) && text_of(chars, run_start, run_end).includes?("crystal")
          return true
        end
        # The candidate's trailing slash can open the next `/share/`
        # (`/share/share/...`). Each character between slashes is still
        # visited a bounded number of times, so the scan stays linear.
        index = run_start - 1
      else
        index += 1
      end
    end
    false
  end

  # Replaces `/\A\$2[abxy]?\$\d{2}\$[.\/A-Za-z0-9]{53}\z/`: the shape of a
  # bcrypt hash.
  def self.bcrypt_digest?(digest : String) : Bool
    chars = digest.chars
    body_start = bcrypt_body_start(chars) || return false
    return false unless chars.size - body_start == 53
    chars.each(within: body_start..) do |char|
      return false unless char.ascii_alphanumeric? || char.in?('.', '/')
    end
    true
  end

  # Replaces `template.gsub(/%\{(\w+)\}/) { |whole, match| ... }`: yields each
  # `%{name}` placeholder and its name, and puts the block's result in its place.
  def self.replace_named_placeholders(template : String, & : String, String -> String) : String
    chars = template.chars
    String.build do |io|
      index = 0
      while index < chars.size
        if chars[index] == '%' && chars[index + 1]? == '{'
          name_end = index + 2
          while name_end < chars.size && CC.word?(chars[name_end])
            name_end += 1
          end
          if name_end > index + 2 && chars[name_end]? == '}'
            io << yield text_of(chars, index, name_end + 1), text_of(chars, index + 2, name_end)
            index = name_end + 1
            next
          end
        end
        io << chars[index]
        index += 1
      end
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
    chars = statement.chars
    found = [] of String
    index = 0
    while index < chars.size
      previous = index > 0 ? chars[index - 1] : nil
      if (previous.nil? || !(CC.word?(previous) || previous == '.')) && (qualifier = qualifier_at(chars, index))
        name_start, name_end, dot = qualifier
        found << text_of(chars, name_start, name_end)
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
    chars = text.chars
    index = skip_spaces(chars, 0)
    name_end = identifier_end(chars, index, fold: true)
    return false if name_end == index || chars[name_end]? != '('
    index = skip_spaces(chars, name_end + 1)
    if reference_end = column_reference_end(chars, index)
      index = reference_end
      loop do
        comma = skip_spaces(chars, index)
        break unless chars[comma]? == ','
        next_reference = skip_spaces(chars, comma + 1)
        reference_end = column_reference_end(chars, next_reference) || return false
        index = reference_end
      end
    end
    index = skip_spaces(chars, index)
    return false unless chars[index]? == ')'
    !sort_tail(chars, index + 1).nil?
  end

  # Replaces `/\A\s*([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?)(?:\s+(asc|desc))?(?:\s+nulls\s+(first|last))?\s*\z/i`:
  # an ORDER BY term naming a column, or `nil`.
  def self.order_term(term : String) : OrderTerm?
    chars = term.chars
    start = skip_spaces(chars, 0)
    column_end = word_name_end(chars, start)
    return if column_end == start
    if chars[column_end]? == '.'
      qualified_end = word_name_end(chars, column_end + 1)
      column_end = qualified_end if qualified_end > column_end + 1
    end
    tail = sort_tail(chars, column_end) || return
    OrderTerm.new(text_of(chars, start, column_end), tail[0], tail[1])
  end

  # Replaces `/\s+(asc|desc)(\s+nulls\s+(first|last))?\s*\z/i`: the direction
  # that ends a raw ORDER BY term, or `nil`.
  def self.raw_direction(part : String) : RawDirection?
    chars = part.chars
    stop = chars.size
    while stop > 0 && CC.space?(chars[stop - 1])
      stop -= 1
    end
    nulls = nil
    placement_start = trailing_keyword_start(chars, stop, {"first", "last"})
    if placement_start && (nulls_start = keyword_before_spaces(chars, placement_start, "nulls"))
      nulls = text_of(chars, placement_start, stop)
      stop = last_non_space_end(chars, nulls_start)
    end
    direction_start = trailing_keyword_start(chars, stop, {"asc", "desc"}) || return
    return unless direction_start > 0 && CC.space?(chars[direction_start - 1])
    run_start = direction_start - 1
    while run_start > 0 && CC.space?(chars[run_start - 1])
      run_start -= 1
    end
    RawDirection.new(run_start, text_of(chars, direction_start, stop), nulls)
  end

  # Replaces `table.rindex(/\s+as\s+/i)` followed by
  # `table[index..].sub(/\A\s+as\s+/i, "")`: the alias of a joined table, or
  # the table itself when it has none.
  def self.join_qualifier(table : String) : String
    chars = table.chars
    alias_start = nil
    index = 0
    while index < chars.size
      if CC.space?(chars[index])
        run_end = skip_spaces(chars, index)
        if keyword_at?(chars, run_end, "as") && (after = spaces_after(chars, run_end + 2))
          alias_start = after
          index = after
        else
          index = run_end
        end
      else
        index += 1
      end
    end
    alias_start ? text_of(chars, alias_start, chars.size) : table
  end

  # Replaces scanning
  # `/\bJOIN\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s+(?:AS\s+)?(?!ON\b|USING\b|INNER\b|LEFT\b|RIGHT\b|FULL\b|CROSS\b|NATURAL\b|JOIN\b)([A-Za-z_][A-Za-z0-9_]*))?/i`
  # and taking `match[2]? || match[1]`: the alias (or table) each raw JOIN
  # makes available.
  def self.raw_join_targets(clause : String) : Array(String)
    chars = clause.chars
    found = [] of String
    index = 0
    while index < chars.size
      if boundary_before?(chars, index) && keyword_at?(chars, index, "join") && (table_start = spaces_after(chars, index + 4))
        table_end = identifier_end(chars, table_start, fold: true)
        if table_end > table_start
          alias_range = join_alias_range(chars, table_end)
          if alias_range
            found << text_of(chars, alias_range[0], alias_range[1])
            index = alias_range[1]
          else
            found << text_of(chars, table_start, table_end)
            index = table_end
          end
          next
        end
      end
      index += 1
    end
    found
  end

  # Replaces scanning `/["`]?([A-Za-z_][A-Za-z0-9_]*)["`]?\s*(?:=|!=|<>|<=|>=|<|>|\bLIKE|\bILIKE)\s*(\?|\$\d+)/i`:
  # every `column <op> placeholder` predicate.
  def self.comparison_binds(query : String) : Array(ComparisonBind)
    chars = query.chars
    found = [] of ComparisonBind
    index = 0
    while index < chars.size
      name_start = log_quote?(chars[index]) ? index + 1 : index
      name_end = identifier_end(chars, name_start, fold: true)
      if name_end > name_start
        if placeholder = comparison_placeholder(chars, name_end)
          found << ComparisonBind.new(text_of(chars, name_start, name_end), placeholder)
          index = placeholder.index + placeholder.text.size
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
    chars = query.chars
    closes = next_close_parens(chars)
    found = [] of InListBind
    index = 0
    while index < chars.size
      name_start = log_quote?(chars[index]) ? index + 1 : index
      name_end = identifier_end(chars, name_start, fold: true)
      if name_end > name_start
        if list = in_list_range(chars, closes, name_end)
          found << InListBind.new(text_of(chars, name_start, name_end), placeholders_in(chars, list[0], list[1]))
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
    chars = query.chars
    closes = next_close_parens(chars)
    chars.each_index do |index|
      next unless keyword_at?(chars, index, "insert")
      into = spaces_after(chars, index + 6) || next
      next unless keyword_at?(chars, into, "into")
      target_start = spaces_after(chars, into + 4) || next
      target_end = target_start
      while target_end < chars.size && !CC.space?(chars[target_end])
        target_end += 1
      end
      next if target_end == target_start
      # `\S+` gives back characters from its end until `\s*\(` can follow.
      target_end.downto(target_start + 1) do |candidate|
        open = candidate == target_end ? skip_spaces(chars, candidate) : candidate
        next unless chars[open]? == '('
        close = closes[open + 1]? || next
        values = skip_spaces(chars, close + 1)
        next unless keyword_at?(chars, values, "values")
        rest = skip_spaces(chars, values + 6)
        return InsertBinds.new(text_of(chars, open + 1, close), placeholders_in(chars, rest, chars.size))
      end
    end
    nil
  end

  # Replaces `/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i`.
  def self.email?(value : String) : Bool
    chars = value.chars
    at = chars.index('@') || return false
    return false if at == 0
    chars.each(within: 0...at) do |char|
      return false unless CC.word?(char) || char.in?('+', '-', '.')
    end
    labels = [] of Array(Char)
    current = [] of Char
    chars.each(within: (at + 1)..) do |char|
      if char == '.'
        labels << current
        current = [] of Char
      else
        current << char
      end
    end
    labels << current
    return false if labels.size < 2 || labels.any?(&.empty?)
    labels.each_with_index do |label, position|
      last = position == labels.size - 1
      label.each do |char|
        letter = CC.ascii_letter_ignoring_case?(char)
        return false unless last ? letter : (letter || CC.digit?(char) || char == '-')
      end
    end
    true
  end

  # Replaces
  # `/\Ahttps?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&\/\/=]*)\z/`.
  def self.url?(value : String) : Bool
    chars = value.chars
    prefix = if chars_at?(chars, 0, "https://".chars)
               8
             elsif chars_at?(chars, 0, "http://".chars)
               7
             else
               return false
             end
    return true if url_host_and_path?(chars, prefix)
    chars_at?(chars, prefix, "www.".chars) && url_host_and_path?(chars, prefix + 4)
  end

  # --- building blocks -----------------------------------------------------

  private def self.text_of(chars : Array(Char), start : Int32, stop : Int32) : String
    String.build(stop - start) do |io|
      chars.each(within: start...stop) { |char| io << char }
    end
  end

  private def self.chars_at?(chars : Array(Char), index : Int32, needle : Array(Char)) : Bool
    return false if index < 0 || index + needle.size > chars.size
    needle.each_with_index { |char, offset| return false unless chars[index + offset] == char }
    true
  end

  # Whether the lowercase ASCII *keyword* starts at *index*, ignoring case as a
  # `/i` regex does.
  private def self.keyword_at?(chars : Array(Char), index : Int32, keyword : String) : Bool
    return false if index < 0 || index + keyword.size > chars.size
    keyword.each_char_with_index do |letter, offset|
      return false unless CC.letter_ignoring_case?(chars[index + offset], letter)
    end
    true
  end

  # The end of `KEYWORD(\s+KEYWORD)*` at *index*, or `nil`.
  private def self.keyword_sequence_end(chars : Array(Char), index : Int32, keywords : Tuple) : Int32?
    position = index
    keywords.each_with_index do |keyword, number|
      if number > 0
        position = spaces_after(chars, position) || return
      end
      return unless keyword_at?(chars, position, keyword)
      position += keyword.size
    end
    position
  end

  private def self.skip_spaces(chars : Array(Char), index : Int32) : Int32
    position = index
    while position < chars.size && CC.space?(chars[position])
      position += 1
    end
    position
  end

  # The end of a `\s+` run at *index*, or `nil` when there is no white space.
  private def self.spaces_after(chars : Array(Char), index : Int32) : Int32?
    position = skip_spaces(chars, index)
    position > index ? position : nil
  end

  private def self.boundary_before?(chars : Array(Char), index : Int32) : Bool
    CC.word_boundary?(index > 0 ? chars[index - 1]? : nil, chars[index]?)
  end

  # Whether *chars* holds `\b(ORDER\s+BY|LIMIT|OFFSET|GROUP\s+BY)\b`, ignoring case.
  private def self.trailing_clause_keyword_in?(chars : Array(Char)) : Bool
    chars.each_index do |index|
      next unless boundary_before?(chars, index)
      {% for words in [{"order", "by"}, {"limit"}, {"offset"}, {"group", "by"}] %}
        if stop = keyword_sequence_end(chars, index, {{words}})
          return true if boundary_before?(chars, stop)
        end
      {% end %}
    end
    false
  end

  # Whether the lowercase ASCII *keyword* appears in *chars* as a whole word,
  # ignoring case.
  private def self.whole_keyword?(chars : Array(Char), keyword : String) : Bool
    chars.each_index.any? do |index|
      boundary_before?(chars, index) && keyword_at?(chars, index, keyword) && boundary_before?(chars, index + keyword.size)
    end
  end

  # Stands in for each character of quoted SQL text: neither a word character
  # nor white space, so no keyword or word boundary forms across it.
  private QUOTED_TEXT_MASK = '\0'

  # A copy of *chars* with every single-quoted literal and every double-quoted
  # or backtick identifier (delimiters included) replaced by
  # `QUOTED_TEXT_MASK`. A doubled delimiter inside the quotes (`''`, `""`)
  # stands for itself; an unclosed quote runs to the end of the text.
  private def self.mask_quoted_text(chars : Array(Char)) : Array(Char)
    masked = chars.dup
    closing : Char? = nil
    index = 0
    while index < chars.size
      char = chars[index]
      if quote = closing
        masked[index] = QUOTED_TEXT_MASK
        if char == quote && chars[index + 1]? == quote
          index += 1
          masked[index] = QUOTED_TEXT_MASK
        elsif char == quote
          closing = nil
        end
      elsif char.in?('\'', '"', '`')
        masked[index] = QUOTED_TEXT_MASK
        closing = char
      end
      index += 1
    end
    masked
  end

  # The end of `[A-Za-z_][A-Za-z0-9_]*` at *index* (*index* itself when none
  # starts there). With *fold*, the letters match as in a `/i` regex.
  private def self.identifier_end(chars : Array(Char), index : Int32, *, fold : Bool) : Int32
    first = chars[index]? || return index
    return index unless first == '_' || (fold ? CC.ascii_letter_ignoring_case?(first) : first.ascii_letter?)
    position = index + 1
    while position < chars.size
      char = chars[position]
      break unless char == '_' || char.ascii_number? || (fold ? CC.ascii_letter_ignoring_case?(char) : char.ascii_letter?)
      position += 1
    end
    position
  end

  # The end of `[A-Za-z_]\w*` (case-insensitive) at *index*.
  private def self.word_name_end(chars : Array(Char), index : Int32) : Int32
    first = chars[index]? || return index
    return index unless first == '_' || CC.ascii_letter_ignoring_case?(first)
    position = index + 1
    while position < chars.size && CC.word?(chars[position])
      position += 1
    end
    position
  end

  # The end of `REF` (see `.column_function?`) at *index*, or `nil`.
  private def self.column_reference_end(chars : Array(Char), index : Int32) : Int32?
    first_end = identifier_end(chars, index, fold: true)
    return if first_end == index
    if chars[first_end]? == '.'
      second_end = identifier_end(chars, first_end + 1, fold: true)
      return second_end if second_end > first_end + 1
    end
    first_end
  end

  # Matches `(?:\s+(asc|desc))?(?:\s+nulls\s+(first|last))?\s*\z` (ignoring
  # case) at *index*: the direction and NULL placement as written, or `nil`
  # when the rest of the text has another shape.
  private def self.sort_tail(chars : Array(Char), index : Int32) : {String?, String?}?
    position = index
    direction = nil
    if start = spaces_after(chars, position)
      word = {"asc", "desc"}.find { |candidate| keyword_at?(chars, start, candidate) }
      if word
        direction = text_of(chars, start, start + word.size)
        position = start + word.size
      end
    end
    nulls = nil
    if (start = spaces_after(chars, position)) && keyword_at?(chars, start, "nulls") && (placement_start = spaces_after(chars, start + 5))
      word = {"first", "last"}.find { |candidate| keyword_at?(chars, placement_start, candidate) }
      if word
        nulls = text_of(chars, placement_start, placement_start + word.size)
        position = placement_start + word.size
      end
    end
    skip_spaces(chars, position) == chars.size ? {direction, nulls} : nil
  end

  # The start of one of *keywords* that ends exactly at *stop*, or `nil`.
  private def self.trailing_keyword_start(chars : Array(Char), stop : Int32, keywords : Tuple) : Int32?
    keywords.each do |keyword|
      start = stop - keyword.size
      return start if keyword_at?(chars, start, keyword)
    end
    nil
  end

  # When `KEYWORD\s+` ends at *index*, the start of the white space before
  # KEYWORD, provided there is some; otherwise `nil`.
  private def self.keyword_before_spaces(chars : Array(Char), index : Int32, keyword : String) : Int32?
    run_start = index
    while run_start > 0 && CC.space?(chars[run_start - 1])
      run_start -= 1
    end
    return if run_start == index
    keyword_start = run_start - keyword.size
    return unless keyword_at?(chars, keyword_start, keyword)
    return unless keyword_start > 0 && CC.space?(chars[keyword_start - 1])
    keyword_start
  end

  private def self.last_non_space_end(chars : Array(Char), stop : Int32) : Int32
    position = stop
    while position > 0 && CC.space?(chars[position - 1])
      position -= 1
    end
    position
  end

  # `[A-Za-z_]` when *first*, `[A-Za-z0-9_]` otherwise.
  private def self.identifier_char?(char : Char, *, first : Bool) : Bool
    char == '_' || char.ascii_letter? || (!first && char.ascii_number?)
  end

  private def self.sql_word_char?(char : Char) : Bool
    char.ascii_alphanumeric? || char.in?('_', '$', '\'')
  end

  private def self.log_quote?(char : Char) : Bool
    char == '"' || char == '`'
  end

  private def self.digit_run_end(chars : Array(Char), index : Int32) : Int32
    position = index
    while position < chars.size && CC.digit?(chars[position])
      position += 1
    end
    position
  end

  # Matches `\A\$2[abxy]?\$\d{2}\$`, the prefix of a bcrypt hash: where the
  # hash body starts, or `nil`.
  private def self.bcrypt_body_start(chars : Array(Char)) : Int32?
    return unless chars[0]? == '$' && chars[1]? == '2'
    index = 2
    index += 1 if chars[index]?.try(&.in?('a', 'b', 'x', 'y'))
    return unless chars[index]? == '$'
    first_digit = chars[index + 1]?
    second_digit = chars[index + 2]?
    return unless first_digit && second_digit && CC.digit?(first_digit) && CC.digit?(second_digit)
    return unless chars[index + 3]? == '$'
    index + 4
  end

  # Matches `"?([A-Za-z_][A-Za-z0-9_]*)"?\.(?=["A-Za-z_])` at *index*: the
  # start and end of the qualifier name and the index of its dot, or `nil`.
  private def self.qualifier_at(chars : Array(Char), index : Int32) : {Int32, Int32, Int32}?
    name_start = chars[index] == '"' ? index + 1 : index
    name_end = identifier_end(chars, name_start, fold: false)
    return if name_end == name_start
    dot = chars[name_end]? == '"' ? name_end + 1 : name_end
    following = chars[dot + 1]?
    return unless chars[dot]? == '.' && following
    return unless following == '"' || following == '_' || following.ascii_letter?
    {name_start, name_end, dot}
  end

  # The end of a URL scheme `[A-Za-z][A-Za-z0-9+.\-]*` at the start, or `nil`.
  private def self.scheme_end(chars : Array(Char)) : Int32?
    return unless chars[0]?.try(&.ascii_letter?)
    position = 1
    while position < chars.size && (chars[position].ascii_alphanumeric? || chars[position].in?('+', '.', '-'))
      position += 1
    end
    position
  end

  # `'(?:[^'\\]|''|\\.)*'` as the whole text.
  private def self.quoted_mysql_string?(chars : Array(Char)) : Bool
    return false unless chars.size >= 2 && chars.first == '\'' && chars.last == '\''
    index = 1
    stop = chars.size - 1
    while index < stop
      case chars[index]
      when '\''
        return false unless index + 1 < stop && chars[index + 1] == '\''
        index += 2
      when '\\'
        return false unless index + 1 < stop && chars[index + 1] != '\n'
        index += 2
      else
        index += 1
      end
    end
    true
  end

  # `\b\d+\b` replaced by `?`.
  private def self.replace_standalone_numbers(text : String) : String
    chars = text.chars
    String.build do |io|
      index = 0
      while index < chars.size
        if CC.digit?(chars[index])
          run_end = digit_run_end(chars, index)
          before = index > 0 ? chars[index - 1] : nil
          after = chars[run_end]?
          if (before.nil? || !CC.word?(before)) && (after.nil? || !CC.word?(after))
            io << '?'
          else
            chars.each(within: index...run_end) { |char| io << char }
          end
          index = run_end
        else
          io << chars[index]
          index += 1
        end
      end
    end
  end

  # `'[^']*'` replaced by `?`.
  private def self.replace_quoted_strings(text : String) : String
    return text unless text.includes?('\'')
    chars = text.chars
    String.build do |io|
      index = 0
      while index < chars.size
        if chars[index] == '\'' && (close = chars.index('\'', index + 1))
          io << '?'
          index = close + 1
        else
          io << chars[index]
          index += 1
        end
      end
    end
  end

  # `\s+` replaced by one space.
  private def self.collapse_spaces(text : String) : String
    chars = text.chars
    String.build do |io|
      index = 0
      while index < chars.size
        if CC.space?(chars[index])
          io << ' '
          index = skip_spaces(chars, index)
        else
          io << chars[index]
          index += 1
        end
      end
    end
  end

  # `[`"\[]?([\w.$]+)` at *index*: the reference without its opening quote.
  private def self.table_reference_at(chars : Array(Char), index : Int32) : String?
    start = chars[index]?.try(&.in?('`', '"', '[')) ? index + 1 : index
    stop = start
    while stop < chars.size && (CC.word?(chars[stop]) || chars[stop].in?('.', '$'))
      stop += 1
    end
    stop > start ? text_of(chars, start, stop) : nil
  end

  # The alias part of a raw JOIN after its table name, as `{start, end}`.
  private def self.join_alias_range(chars : Array(Char), table_end : Int32) : {Int32, Int32}?
    start = spaces_after(chars, table_end) || return
    if keyword_at?(chars, start, "as") && (after_as = spaces_after(chars, start + 2))
      if join_alias_allowed?(chars, after_as)
        stop = identifier_end(chars, after_as, fold: true)
        return {after_as, stop} if stop > after_as
      end
    end
    return unless join_alias_allowed?(chars, start)
    stop = identifier_end(chars, start, fold: true)
    stop > start ? {start, stop} : nil
  end

  private def self.join_alias_allowed?(chars : Array(Char), index : Int32) : Bool
    {"on", "using", "inner", "left", "right", "full", "cross", "natural", "join"}.none? do |keyword|
      keyword_at?(chars, index, keyword) && boundary_before?(chars, index + keyword.size)
    end
  end

  # `["`]?\s*(?:=|!=|<>|<=|>=|<|>|\bLIKE|\bILIKE)\s*(\?|\$\d+)` after a name.
  private def self.comparison_placeholder(chars : Array(Char), name_end : Int32) : Placeholder?
    position = chars[name_end]?.try { |char| log_quote?(char) } ? name_end + 1 : name_end
    operator_start = skip_spaces(chars, position)
    {"=", "!=", "<>", "<=", ">=", "<", ">"}.each do |operator|
      if chars_at?(chars, operator_start, operator.chars)
        if placeholder = placeholder_at(chars, skip_spaces(chars, operator_start + operator.size))
          return placeholder
        end
      end
    end
    {"like", "ilike"}.each do |operator|
      if boundary_before?(chars, operator_start) && keyword_at?(chars, operator_start, operator)
        if placeholder = placeholder_at(chars, skip_spaces(chars, operator_start + operator.size))
          return placeholder
        end
      end
    end
    nil
  end

  # `\?|\$\d+` exactly at *index*.
  private def self.placeholder_at(chars : Array(Char), index : Int32) : Placeholder?
    case chars[index]?
    when '?'
      Placeholder.new("?", index)
    when '$'
      digits_end = digit_run_end(chars, index + 1)
      digits_end > index + 1 ? Placeholder.new(text_of(chars, index, digits_end), index) : nil
    end
  end

  # Every `\?|\$\d+` in `chars[start...stop]`.
  private def self.placeholders_in(chars : Array(Char), start : Int32, stop : Int32) : Array(Placeholder)
    found = [] of Placeholder
    index = start
    while index < stop
      digits_end = chars[index] == '$' ? digit_run_end(chars, index + 1) : index
      digits_end = stop if digits_end > stop
      if chars[index] == '?'
        found << Placeholder.new("?", index)
        index += 1
      elsif chars[index] == '$' && digits_end > index + 1
        found << Placeholder.new(text_of(chars, index, digits_end), index)
        index = digits_end
      else
        index += 1
      end
    end
    found
  end

  # For each index, the index of the first `)` at or after it.
  private def self.next_close_parens(chars : Array(Char)) : Array(Int32?)
    closes = Array(Int32?).new(chars.size + 1, nil)
    following = nil
    (chars.size - 1).downto(0) do |index|
      following = index if chars[index] == ')'
      closes[index] = following
    end
    closes
  end

  # `["`]?\s+(?:NOT\s+)?IN\s*\(([^)]*)\)` after a name: the range inside the
  # parentheses.
  private def self.in_list_range(chars : Array(Char), closes : Array(Int32?), name_end : Int32) : {Int32, Int32}?
    position = chars[name_end]?.try { |char| log_quote?(char) } ? name_end + 1 : name_end
    start = spaces_after(chars, position) || return
    if keyword_at?(chars, start, "not") && (after_not = spaces_after(chars, start + 3))
      if range = in_parentheses(chars, closes, after_not)
        return range
      end
    end
    in_parentheses(chars, closes, start)
  end

  private def self.in_parentheses(chars : Array(Char), closes : Array(Int32?), index : Int32) : {Int32, Int32}?
    return unless keyword_at?(chars, index, "in")
    open = skip_spaces(chars, index + 2)
    return unless chars[open]? == '('
    close = closes[open + 1]? || return
    {open + 1, close}
  end

  # `[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b[-a-zA-Z0-9()@:%_\+.~#?&\/\/=]*\z`
  # from *start*.
  private def self.url_host_and_path?(chars : Array(Char), start : Int32) : Bool
    host_run = start
    while host_run < chars.size && url_host_char?(chars[host_run])
      host_run += 1
    end
    path_start = chars.size
    while path_start > start && url_path_char?(chars[path_start - 1])
      path_start -= 1
    end
    last_dot = Math.min(host_run, start + 256)
    (start + 1..last_dot).each do |dot|
      next unless chars[dot]? == '.'
      (1..6).each do |length|
        stop = dot + 1 + length
        break if stop > chars.size || !url_tld_char?(chars[stop - 1])
        next if stop < path_start
        return true if CC.word_boundary?(chars[stop - 1], chars[stop]?)
      end
    end
    false
  end

  private def self.url_host_char?(char : Char) : Bool
    char.ascii_alphanumeric? || char.in?('-', '@', ':', '%', '.', '_', '+', '~', '#', '=')
  end

  private def self.url_tld_char?(char : Char) : Bool
    char.ascii_alphanumeric? || char.in?('(', ')')
  end

  private def self.url_path_char?(char : Char) : Bool
    char.ascii_alphanumeric? || char.in?('-', '(', ')', '@', ':', '%', '_', '+', '.', '~', '#', '?', '&', '/', '=')
  end
end
