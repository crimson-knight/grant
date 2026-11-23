require "../../../src/grant/sqlite_engine"

# C SQLite's verdict on SQL text, for comparison with the engine's parser.
# Links the C library, so only specs and scripts load it; the engine itself
# never does.
module SQLiteSQLOracle
  @[Link("sqlite3")]
  lib LibOracle
    type Database = Void*
    type Statement = Void*

    fun open_v2 = sqlite3_open_v2(filename : UInt8*, database : Database*, flags : Int32, vfs : UInt8*) : Int32
    fun close_v2 = sqlite3_close_v2(database : Database) : Int32
    fun prepare_v2 = sqlite3_prepare_v2(database : Database, sql : UInt8*, bytes : Int32, statement : Statement*, tail : UInt8**) : Int32
    fun finalize = sqlite3_finalize(statement : Statement) : Int32
    fun step = sqlite3_step(statement : Statement) : Int32
    fun column_count = sqlite3_column_count(statement : Statement) : Int32
    fun column_text = sqlite3_column_text(statement : Statement, column : Int32) : UInt8*
    fun errmsg = sqlite3_errmsg(database : Database) : UInt8*
    fun exec = sqlite3_exec(database : Database, sql : UInt8*, callback : Void*, argument : Void*, error : UInt8**) : Int32
    fun libversion = sqlite3_libversion : UInt8*
    fun complete = sqlite3_complete(sql : UInt8*) : Int32
    fun sourceid = sqlite3_sourceid : UInt8*
  end

  OPEN_READWRITE_CREATE = 0x02 | 0x04
  ROW                   = 100

  enum Verdict
    Accepted
    Rejected
    # C stopped early on an error that depends on the database's contents
    # (a missing table or schema), so its verdict on the rest of the text
    # is unknown.
    Undetermined
  end

  record Outcome, verdict : Verdict, message : String?

  # Messages C SQLite's parser raises from the grammar or its actions,
  # wherever they stop it.
  PARSE_MESSAGES = [
    /syntax error/, /\Aincomplete input\z/, /\Aunrecognized token/, /\Aunknown table option/,
    /clause should come after .* not before\z/, /\Atoo many terms in compound SELECT\z/,
    /\Avariable number must be between/, /\Atoo many SQL variables\z/,
    /\Astring or blob too big\z/, /\Aparser stack overflow\z/, /\Atoo many arguments on function/,
    /\ADISTINCT is not supported for window functions\z/, /\Aunsupported frame specification\z/,
    /\Aqualified table names are not allowed/, /\Athe (INDEXED BY|NOT INDEXED) clause is not allowed/,
    /\Aa JOIN clause is required before/, /\Aunknown join type/,
  ]

  # Messages SQLite raises from checks that do not depend on the database
  # (build.c and the grammar's helpers). Raised at the last token they are
  # indistinguishable by position from errors after parsing, so they are
  # recognized by text.
  ACTION_MESSAGES = [
    /\Aduplicate column name/, /\Atoo many columns on/, /has more than one primary key\z/,
    /\AAUTOINCREMENT is only allowed/, /\Adefault value of column .* is not constant\z/,
    /\Acannot use DEFAULT on a generated column\z/, /\Aerror in generated column/,
    /\Agenerated columns cannot be part of the PRIMARY KEY\z/, /should reference only one column of table/,
    /\Anumber of columns in foreign key does not match/, /\Aunknown column .* in foreign key definition\z/,
    /\Aexpressions prohibited in PRIMARY KEY and UNIQUE constraints\z/, /\Aobject name reserved for internal use/,
    /\Atemporary table name must be unqualified\z/, /\Atemporary trigger may not have qualified name\z/,
    /\Aunsupported use of NULLS/, /\Acannot use RETURNING in a trigger\z/, /\Aduplicate WITH table name/,
    /\Aconflicting ON CONFLICT clauses specified\z/,
  ]

  # Messages raised both by the parser and by name resolution: a stop
  # before the end is a parse error, a stop at the end is unknown.
  AMBIGUOUS_MESSAGES = [/\Aall VALUES must have the same number of terms\z/, /\AExpression tree is too large/]

  # Messages that depend on what the database holds.
  DATABASE_MESSAGES = [
    /\Ano such (table|view|index|trigger|module|collation sequence|savepoint|column)/, /\Aunknown database/,
    /already exists\z/, /\Acannot create .*trigger/, /\Acannot (add|drop|rename)/, /\Aview .* may not be altered\z/,
    /\Atable .* may not be (altered|modified)\z/,
    /cannot reference objects in database/, /has no column named/, /\Avirtual tables may not be altered\z/,
  ]

  def self.version : String
    "#{String.new(LibOracle.libversion)} #{String.new(LibOracle.sourceid)}"
  end

  def self.open_memory : LibOracle::Database
    status = LibOracle.open_v2(":memory:", out database, OPEN_READWRITE_CREATE, nil)
    raise "sqlite3_open_v2 failed: #{status}" unless status == 0
    database
  end

  # The verdict of `sqlite3_prepare_v2` on an empty in-memory database. A
  # stop on a missing table or schema is retried once the object exists.
  def self.verdict(sql : String) : Outcome
    setup = [] of String
    outcome = Outcome.new(Verdict::Undetermined, nil)
    early = true
    6.times do
      database = open_memory
      begin
        setup.each { |statement| LibOracle.exec(database, statement, nil, nil, nil) }
        outcome, retry_setup, early = verdict_in(database, sql)
        return outcome unless retry_setup
        fresh = retry_setup.reject { |statement| setup.includes?(statement) }
        break if fresh.empty?
        setup.concat(fresh)
      ensure
        LibOracle.close_v2(database)
      end
    end
    # A database error at the very end means C read the whole statement.
    return Outcome.new(Verdict::Accepted, outcome.message) if outcome.verdict.undetermined? && !early
    outcome
  end

  private def self.verdict_in(database : LibOracle::Database, original : String) : {Outcome, Array(String)?, Bool}
    sql = terminated(original)
    status = LibOracle.prepare_v2(database, sql, sql.bytesize, out statement, out tail)
    LibOracle.finalize(statement) unless statement.null?
    return {Outcome.new(Verdict::Accepted, nil), nil, false} if status == 0
    message = String.new(LibOracle.errmsg(database)).scrub
    if PARSE_MESSAGES.any?(&.matches?(message)) || ACTION_MESSAGES.any?(&.matches?(message))
      return {Outcome.new(Verdict::Rejected, message), nil, false}
    end
    consumed = tail.null? ? sql.bytesize : (tail.address - sql.to_unsafe.address).to_i32
    early = stopped_early?(sql, consumed)
    if DATABASE_MESSAGES.any?(&.matches?(message))
      # Retried once the missing object exists; with nothing to create, a stop
      # at the end still means the parser read the whole statement.
      setup = setup_for(message, sql)
      return {Outcome.new(Verdict::Accepted, message), nil, false} unless setup || early
      return {Outcome.new(Verdict::Undetermined, message), setup, early}
    end
    if AMBIGUOUS_MESSAGES.any?(&.matches?(message))
      return {Outcome.new(early ? Verdict::Rejected : Verdict::Undetermined, message), nil, early}
    end
    {Outcome.new(early ? Verdict::Rejected : Verdict::Accepted, message), nil, early}
  end

  # *sql* ending in a semicolon, so that C stops after that semicolon only
  # when it parsed the whole statement.
  private def self.terminated(sql : String) : String
    return sql if last_token_kind(sql).semicolon?
    candidate = sql + "\n;"
    # An unterminated comment at the end would swallow the semicolon.
    last_token_kind(candidate).semicolon? ? candidate : sql
  end

  private def self.last_token_kind(sql : String) : Grant::SQLiteEngine::SQL::TokenKind
    tokenizer = Grant::SQLiteEngine::SQL::Tokenizer.new(sql)
    last = Grant::SQLiteEngine::SQL::TokenKind::EndOfInput
    loop do
      token = tokenizer.next_token
      break if token.kind.end_of_input?
      last = token.kind
    end
    last
  end

  # True when any token follows the point where C stopped.
  private def self.stopped_early?(sql : String, consumed : Int32) : Bool
    rest = sql.byte_slice(consumed, sql.bytesize - consumed)
    !Grant::SQLiteEngine::SQL::Tokenizer.new(rest).next_token.kind.end_of_input?
  end

  # The statement that creates what a database-dependent error found
  # missing.
  private def self.setup_for(message : String, sql : String) : Array(String)?
    if match = message.match(/\Ano such table: (?:([^.]+)\.)?(.+)\z/)
      schema = (match[1]? || "main").gsub(%("), "")
      name = match[2].gsub(%("), %(""))
      setup = [] of String
      setup << %(ATTACH ':memory:' AS "#{schema}") unless schema.in?("main", "temp")
      if sql.scrub =~ /INSTEAD\s+OF/i
        setup << %(CREATE VIEW "#{schema}"."#{name}" AS SELECT 1 AS "__oracle_column__")
      else
        setup << %(CREATE TABLE "#{schema}"."#{name}" ("__oracle_column__"))
      end
      return setup
    end
    if match = message.match(/\Aunknown database (.+)\z/)
      return [%(ATTACH ':memory:' AS "#{match[1].gsub(%("), "")}")]
    end
    nil
  end

  # Splits *block* into statements where sqlite3_complete says a statement
  # ends, as the sqlite3 shell does.
  def self.split_statements(block : String) : Array(String)
    statements = [] of String
    start = 0
    bytes = block.to_slice
    bytes.each_with_index do |byte, index|
      next unless byte == 0x3b_u8
      candidate = block.byte_slice(start, index + 1 - start)
      next unless LibOracle.complete(candidate) == 1
      statements << candidate unless candidate.strip == ";"
      start = index + 1
    end
    rest = block.byte_slice(start, block.bytesize - start)
    statements << rest unless rest.strip.empty?
    statements
  end

  # The engine's verdict on the same text.
  def self.engine_verdict(sql : String) : Outcome
    Grant::SQLiteEngine::SQL::Parser.parse(sql)
    Outcome.new(Verdict::Accepted, nil)
  rescue error : Grant::SQLiteEngine::SQL::ParseError
    Outcome.new(Verdict::Rejected, error.message)
  end

  # The bytecode listing of `EXPLAIN sql` on *database*, or nil when C
  # cannot prepare it.
  def self.bytecode(database : LibOracle::Database, sql : String) : Array(String)?
    explain = "EXPLAIN #{sql}"
    status = LibOracle.prepare_v2(database, explain, explain.bytesize, out statement, nil)
    if status != 0 || statement.null?
      LibOracle.finalize(statement) unless statement.null?
      return nil
    end
    rows = [] of String
    columns = LibOracle.column_count(statement)
    while LibOracle.step(statement) == ROW
      row = (1...columns).map do |column|
        text = LibOracle.column_text(statement, column)
        text.null? ? "" : String.new(text)
      end
      rows << row.join('|')
    end
    LibOracle.finalize(statement)
    rows
  end

  # A database holding every table and index the corpus creates, first
  # definition kept, for comparing bytecode.
  def self.schema_database(statements : Array(String)) : LibOracle::Database
    database = open_memory
    statements.each do |sql|
      next unless sql.lstrip.upcase.starts_with?("CREATE")
      LibOracle.exec(database, sql, nil, nil, nil)
    end
    database
  end
end
