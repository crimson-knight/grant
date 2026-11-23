module Grant::SQLiteEngine::SQL
  module Keywords
    # mkkeywordhash.c's keyword table for a default build (no
    # SQLITE_ENABLE_ORDERED_SET_AGGREGATES, so WITHIN is an identifier).
    TABLE = {
      "ABORT" => TokenKind::Abort, "ACTION" => TokenKind::Action, "ADD" => TokenKind::Add,
      "AFTER" => TokenKind::After, "ALL" => TokenKind::All, "ALTER" => TokenKind::Alter,
      "ALWAYS" => TokenKind::Always, "ANALYZE" => TokenKind::Analyze, "AND" => TokenKind::And,
      "AS" => TokenKind::As, "ASC" => TokenKind::Asc, "ATTACH" => TokenKind::Attach,
      "AUTOINCREMENT" => TokenKind::Autoincrement, "BEFORE" => TokenKind::Before,
      "BEGIN" => TokenKind::Begin, "BETWEEN" => TokenKind::Between, "BY" => TokenKind::By,
      "CASCADE" => TokenKind::Cascade, "CASE" => TokenKind::Case, "CAST" => TokenKind::Cast,
      "CHECK" => TokenKind::Check, "COLLATE" => TokenKind::Collate, "COLUMN" => TokenKind::Column,
      "COMMIT" => TokenKind::Commit, "CONFLICT" => TokenKind::Conflict,
      "CONSTRAINT" => TokenKind::Constraint, "CREATE" => TokenKind::Create,
      "CROSS" => TokenKind::JoinKeyword, "CURRENT" => TokenKind::Current,
      "CURRENT_DATE" => TokenKind::CurrentTimeKeyword, "CURRENT_TIME" => TokenKind::CurrentTimeKeyword,
      "CURRENT_TIMESTAMP" => TokenKind::CurrentTimeKeyword, "DATABASE" => TokenKind::Database,
      "DEFAULT" => TokenKind::Default, "DEFERRED" => TokenKind::Deferred,
      "DEFERRABLE" => TokenKind::Deferrable, "DELETE" => TokenKind::Delete, "DESC" => TokenKind::Desc,
      "DETACH" => TokenKind::Detach, "DISTINCT" => TokenKind::Distinct, "DO" => TokenKind::Do,
      "DROP" => TokenKind::Drop, "END" => TokenKind::End, "EACH" => TokenKind::Each,
      "ELSE" => TokenKind::Else, "ESCAPE" => TokenKind::Escape, "EXCEPT" => TokenKind::Except,
      "EXCLUSIVE" => TokenKind::Exclusive, "EXCLUDE" => TokenKind::Exclude, "EXISTS" => TokenKind::Exists,
      "EXPLAIN" => TokenKind::Explain, "FAIL" => TokenKind::Fail, "FILTER" => TokenKind::Filter,
      "FIRST" => TokenKind::First, "FOLLOWING" => TokenKind::Following, "FOR" => TokenKind::For,
      "FOREIGN" => TokenKind::Foreign, "FROM" => TokenKind::From, "FULL" => TokenKind::JoinKeyword,
      "GENERATED" => TokenKind::Generated, "GLOB" => TokenKind::LikeKeyword, "GROUP" => TokenKind::Group,
      "GROUPS" => TokenKind::Groups, "HAVING" => TokenKind::Having, "IF" => TokenKind::If,
      "IGNORE" => TokenKind::Ignore, "IMMEDIATE" => TokenKind::Immediate, "IN" => TokenKind::In,
      "INDEX" => TokenKind::Index, "INDEXED" => TokenKind::Indexed, "INITIALLY" => TokenKind::Initially,
      "INNER" => TokenKind::JoinKeyword, "INSERT" => TokenKind::Insert, "INSTEAD" => TokenKind::Instead,
      "INTERSECT" => TokenKind::Intersect, "INTO" => TokenKind::Into, "IS" => TokenKind::Is,
      "ISNULL" => TokenKind::IsNull, "JOIN" => TokenKind::Join, "KEY" => TokenKind::Key,
      "LAST" => TokenKind::Last, "LEFT" => TokenKind::JoinKeyword, "LIKE" => TokenKind::LikeKeyword,
      "LIMIT" => TokenKind::Limit, "MATCH" => TokenKind::Match, "MATERIALIZED" => TokenKind::Materialized,
      "NATURAL" => TokenKind::JoinKeyword, "NO" => TokenKind::No, "NOT" => TokenKind::Not,
      "NOTHING" => TokenKind::Nothing, "NOTNULL" => TokenKind::NotNull, "NULL" => TokenKind::Null,
      "NULLS" => TokenKind::Nulls, "OF" => TokenKind::Of, "OFFSET" => TokenKind::Offset,
      "ON" => TokenKind::On, "OR" => TokenKind::Or, "ORDER" => TokenKind::Order,
      "OTHERS" => TokenKind::Others, "OUTER" => TokenKind::JoinKeyword, "OVER" => TokenKind::Over,
      "PARTITION" => TokenKind::Partition, "PLAN" => TokenKind::Plan, "PRAGMA" => TokenKind::Pragma,
      "PRECEDING" => TokenKind::Preceding, "PRIMARY" => TokenKind::Primary, "QUERY" => TokenKind::Query,
      "RAISE" => TokenKind::Raise, "RANGE" => TokenKind::Range, "RECURSIVE" => TokenKind::Recursive,
      "REFERENCES" => TokenKind::References, "REGEXP" => TokenKind::LikeKeyword,
      "REINDEX" => TokenKind::Reindex, "RELEASE" => TokenKind::Release, "RENAME" => TokenKind::Rename,
      "REPLACE" => TokenKind::Replace, "RESTRICT" => TokenKind::Restrict,
      "RETURNING" => TokenKind::Returning, "RIGHT" => TokenKind::JoinKeyword,
      "ROLLBACK" => TokenKind::Rollback, "ROW" => TokenKind::Row, "ROWS" => TokenKind::Rows,
      "SAVEPOINT" => TokenKind::Savepoint, "SELECT" => TokenKind::Select, "SET" => TokenKind::Set,
      "TABLE" => TokenKind::Table, "TEMP" => TokenKind::Temp, "TEMPORARY" => TokenKind::Temp,
      "THEN" => TokenKind::Then, "TIES" => TokenKind::Ties, "TO" => TokenKind::To,
      "TRANSACTION" => TokenKind::Transaction, "TRIGGER" => TokenKind::Trigger,
      "UNBOUNDED" => TokenKind::Unbounded, "UNION" => TokenKind::Union, "UNIQUE" => TokenKind::Unique,
      "UPDATE" => TokenKind::Update, "USING" => TokenKind::Using, "VACUUM" => TokenKind::Vacuum,
      "VALUES" => TokenKind::Values, "VIEW" => TokenKind::View, "VIRTUAL" => TokenKind::Virtual,
      "WHEN" => TokenKind::When, "WHERE" => TokenKind::Where, "WINDOW" => TokenKind::Window,
      "WITH" => TokenKind::With, "WITHOUT" => TokenKind::Without,
    }

    # The longest keyword, CURRENT_TIMESTAMP.
    MAX_KEYWORD_SIZE = 17

    # TABLE by length and first letter (bucket `length * 26 + letter`), so
    # the tokenizer finds a keyword by comparing the bytes it holds,
    # without building a String for each word.
    BUCKETS = begin
      buckets = Array(Array({Bytes, TokenKind})).new((MAX_KEYWORD_SIZE + 1) * 26) { [] of {Bytes, TokenKind} }
      TABLE.each do |word, kind|
        buckets[word.bytesize * 26 + (word.byte_at(0) - 'A'.ord)] << {word.to_slice, kind}
      end
      buckets
    end

    # The keyword spelled by *length* bytes of *bytes* from *start* (any
    # case), or nil.
    def self.lookup(bytes : Bytes, start : Int32, length : Int32) : TokenKind?
      return if length < 2 || length > MAX_KEYWORD_SIZE
      first = upper(bytes[start])
      return unless first >= 'A'.ord && first <= 'Z'.ord
      BUCKETS[length * 26 + (first - 'A'.ord)].each do |(word, kind)|
        matched = true
        1.upto(length - 1) do |index|
          if upper(bytes[start + index]) != word.unsafe_fetch(index)
            matched = false
            break
          end
        end
        return kind if matched
      end
      nil
    end

    private def self.upper(byte : UInt8) : UInt8
      byte >= 'a'.ord && byte <= 'z'.ord ? byte - 32 : byte
    end

    # parse.y's `%fallback ID` list for a default build: these keywords
    # stand as identifiers wherever the grammar has no use for them as
    # keywords. WINDOW, OVER and FILTER are decided by the tokenizer instead
    # (tokenize.c, analyzeWindowKeyword and its siblings).
    FALLBACK_TO_IDENTIFIER = Set{
      TokenKind::Abort, TokenKind::Action, TokenKind::After, TokenKind::Analyze, TokenKind::Asc,
      TokenKind::Attach, TokenKind::Before, TokenKind::Begin, TokenKind::By, TokenKind::Cascade,
      TokenKind::Cast, TokenKind::Column, TokenKind::Conflict, TokenKind::Database,
      TokenKind::Deferred, TokenKind::Desc, TokenKind::Detach, TokenKind::Do, TokenKind::Each,
      TokenKind::End, TokenKind::Exclusive, TokenKind::Explain, TokenKind::Fail, TokenKind::For,
      TokenKind::Ignore, TokenKind::Immediate, TokenKind::Initially, TokenKind::Instead,
      TokenKind::LikeKeyword, TokenKind::Match, TokenKind::No, TokenKind::Plan, TokenKind::Query,
      TokenKind::Key, TokenKind::Of, TokenKind::Offset, TokenKind::Pragma, TokenKind::Raise,
      TokenKind::Recursive, TokenKind::Release, TokenKind::Replace, TokenKind::Restrict,
      TokenKind::Row, TokenKind::Rows, TokenKind::Rollback, TokenKind::Savepoint, TokenKind::Temp,
      TokenKind::Trigger, TokenKind::Vacuum, TokenKind::View, TokenKind::Virtual, TokenKind::With,
      TokenKind::Without, TokenKind::Nulls, TokenKind::First, TokenKind::Last, TokenKind::Current,
      TokenKind::Following, TokenKind::Partition, TokenKind::Preceding, TokenKind::Range,
      TokenKind::Unbounded, TokenKind::Exclude, TokenKind::Groups, TokenKind::Others,
      TokenKind::Ties, TokenKind::Generated, TokenKind::Always, TokenKind::Materialized,
      TokenKind::Reindex, TokenKind::Rename, TokenKind::CurrentTimeKeyword, TokenKind::If,
    }

    def self.falls_back_to_identifier?(kind : TokenKind) : Bool
      FALLBACK_TO_IDENTIFIER.includes?(kind)
    end
  end
end
