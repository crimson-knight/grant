# Generates random schemas, data and SELECT statements for the query
# differential (scripts/sqlite_engine_query_differential.cr). Everything
# comes from one seeded Random, so a seed reproduces a run.
class SQLiteQueryGenerator
  alias Value = Grant::SQLiteEngine::Value

  record GeneratedColumn, column_name : String, declared_type : String, collation : String?
  record GeneratedTable, table_name : String, list_of_columns : Array(GeneratedColumn), rowid_alias : String?

  TYPES      = ["INTEGER", "TEXT", "REAL", "NUMERIC", "BLOB", "", "VARCHAR(20)", "BOOLEAN", "DATETIME", "BIGINT"]
  COLLATIONS = [nil, nil, nil, "NOCASE", "RTRIM", "BINARY"]
  WORDS      = ["a", "A", "b", "abc", "ABC", "abc ", "", " ", "10", "010", "3.5", "1e2", "x%y", "a_c", "Zed", "zed", "élan", "ÉLAN", "-4", "0x10"]

  @list_of_tables = [] of GeneratedTable

  def initialize(seed : Int64)
    @random = Random.new(seed)
  end

  # CREATE and INSERT statements for a new schema of two to four tables.
  def new_schema : Array(String)
    @list_of_tables = [] of GeneratedTable
    statements = [] of String
    rand(2..4).times do |table_index|
      name = "t#{table_index}"
      columns = Array(GeneratedColumn).new(rand(2..5)) do |column_index|
        GeneratedColumn.new("c#{column_index}", TYPES.sample(@random), COLLATIONS.sample(@random))
      end
      alias_name = rand(2) == 0 ? "id" : nil
      @list_of_tables << GeneratedTable.new(name, columns, alias_name)
      definitions = columns.map do |column|
        text = "#{column.column_name} #{column.declared_type}"
        text += " COLLATE #{column.collation}" if column.collation
        text
      end
      definitions.unshift("id INTEGER PRIMARY KEY") if alias_name
      statements << "CREATE TABLE #{name} (#{definitions.join(", ")})"
      rand(0..2).times do |index_number|
        chosen = columns.sample(rand(1..Math.min(2, columns.size)), @random)
        keys = chosen.map do |column|
          key = column.column_name
          key += " COLLATE #{%w[NOCASE BINARY RTRIM].sample(@random)}" if rand(4) == 0
          key += " DESC" if rand(4) == 0
          key
        end
        unique = rand(5) == 0 ? "UNIQUE " : ""
        statements << "CREATE #{unique}INDEX #{name}_i#{index_number} ON #{name} (#{keys.join(", ")})"
      end
      rand(0..30).times do |row_index|
        values = columns.map { literal(random_value) }
        values.unshift(rand(5) == 0 ? "NULL" : (row_index * rand(1..3) + 1).to_s) if alias_name
        statements << "INSERT OR IGNORE INTO #{name} VALUES (#{values.join(", ")})"
      end
    end
    statements
  end

  # One query and its parameter values.
  def query : {String, Array(Value)}
    @parameters = [] of Value
    sql = select_statement(0)
    {sql, @parameters}
  end

  @parameters = [] of Value

  private def rand(range) : Int32
    @random.rand(range)
  end

  private def random_value : Value
    case rand(12)
    when 0, 1    then nil
    when 2, 3, 4 then rand(-3..12).to_i64
    when 5       then [9223372036854775807_i64, -9223372036854775807_i64 - 1, 4611686018427387904_i64].sample(@random)
    when 6, 7    then (rand(-40..40) / 4.0)
    when 8       then [0.1, -0.0, 1e300, 123456789.125, 2.0 ** 63].sample(@random)
    when 9       then Bytes.new(rand(0..3)) { |index| (index * 37 + rand(0..255)).to_u8! }
    else              WORDS.sample(@random)
    end
  end

  private def literal(value : Value) : String
    case value
    when Nil     then "NULL"
    when Int64   then value.to_s
    when Float64 then value == 0.0 && value.sign_bit < 0 ? "-0.0" : (value.finite? ? "%.17g" % value : "1e999")
    when String  then "'#{value.gsub('\'', "''")}'"
    else              "x'#{value.hexstring}'"
    end
  end

  # ------------------------------------------------------------ statements

  private def select_statement(depth : Int32) : String
    sources = pick_sources(depth)
    columns = sources.flat_map { |(table, alias_name)| visible_columns(table, alias_name) }
    aggregate = rand(5) == 0
    grouped = aggregate && rand(2) == 0 && !columns.empty? ? Array.new(rand(1..2)) { columns.sample(@random) } : [] of String
    result = Array(String).new(rand(1..4)) do
      # A bare column in an aggregate query comes from a row the query
      # plan picks, so aggregate queries select aggregates and GROUP BY terms.
      text = if aggregate
               grouped.empty? || rand(2) == 0 ? aggregate_call(columns, depth) : grouped.sample(@random)
             else
               expression(columns, depth, 0)
             end
      rand(4) == 0 ? "#{text} AS r#{rand(0..9)}" : text
    end
    sql = String.build do |io|
      io << "SELECT "
      io << "DISTINCT " if rand(8) == 0
      io << result.join(", ")
      io << " FROM " << from_clause(sources) unless sources.empty?
      io << " WHERE " << condition(columns, depth) if rand(3) > 0
      unless grouped.empty?
        io << " GROUP BY " << grouped.join(", ")
        io << " HAVING " << "#{aggregate_call(columns, depth)} #{%w[> < = >= IS].sample(@random)} #{small_literal}" if rand(3) == 0
      end
    end
    if depth == 0 && rand(6) == 0
      other = select_with_width(result.size, depth)
      sql = "#{sql} #{["UNION", "UNION ALL", "INTERSECT", "EXCEPT"].sample(@random)} #{other}"
    end
    ordered = rand(2) == 0
    if ordered
      terms = (1..result.size).to_a.shuffle(@random).first(rand(1..result.size)).map do |position|
        term = position.to_s
        term += " COLLATE NOCASE" if rand(8) == 0
        term += [" ASC", " DESC", ""].sample(@random)
        term += [" NULLS FIRST", " NULLS LAST"].sample(@random) if rand(6) == 0
        term
      end
      sql += " ORDER BY #{terms.join(", ")}"
    end
    if rand(5) == 0
      sql += " LIMIT #{rand(-1..6)}"
      sql += " OFFSET #{rand(0..3)}" if ordered && rand(2) == 0
    end
    if depth == 0 && rand(12) == 0
      sql = "WITH w(a, b) AS (SELECT #{small_literal}, #{small_literal} UNION ALL SELECT a + 1, b FROM w WHERE a < #{rand(2..6)}) #{sql}"
    end
    sql
  end

  private def select_with_width(width : Int32, depth : Int32) : String
    sources = pick_sources(depth + 1)
    columns = sources.flat_map { |(table, alias_name)| visible_columns(table, alias_name) }
    terms = Array(String).new(width) { expression(columns, depth + 1, 1) }
    from = sources.empty? ? "" : " FROM #{from_clause(sources)}"
    where = rand(2) == 0 ? " WHERE #{condition(columns, depth + 1)}" : ""
    "SELECT #{terms.join(", ")}#{from}#{where}"
  end

  private def pick_sources(depth : Int32) : Array({GeneratedTable, String})
    return [] of {GeneratedTable, String} if rand(15) == 0
    Array({GeneratedTable, String}).new(rand(1..(depth == 0 ? 3 : 2))) do |position|
      {@list_of_tables.sample(@random), "s#{depth}_#{position}"}
    end
  end

  private def visible_columns(table : GeneratedTable, alias_name : String) : Array(String)
    names = table.list_of_columns.map { |column| "#{alias_name}.#{column.column_name}" }
    names << "#{alias_name}.#{table.rowid_alias || "rowid"}"
    names
  end

  private def from_clause(sources : Array({GeneratedTable, String})) : String
    String.build do |io|
      sources.each_with_index do |(table, alias_name), position|
        if position == 0
          io << table.table_name << " AS " << alias_name
          next
        end
        left = visible_columns(*sources[position - 1])
        right = visible_columns(table, alias_name)
        case rand(4)
        when 0
          io << ", " << table.table_name << " AS " << alias_name
        when 1
          io << " LEFT JOIN " << table.table_name << " AS " << alias_name << " ON " << left.sample(@random) << " = " << right.sample(@random)
        else
          io << " JOIN " << table.table_name << " AS " << alias_name << " ON " << left.sample(@random) << " " << %w[= = < >= IS].sample(@random) << " " << right.sample(@random)
        end
      end
    end
  end

  # ----------------------------------------------------------- expressions

  private def small_literal : String
    case rand(6)
    when 0 then "NULL"
    when 1 then "'#{WORDS.sample(@random)}'"
    when 2 then (rand(-20..20) / 2.0).to_s
    when 3
      @parameters << random_value
      "?"
    else rand(-3..12).to_s
    end
  end

  private def expression(columns : Array(String), depth : Int32, level : Int32) : String
    roll = level > 2 ? rand(3) : rand(20)
    case roll
    when 0, 1, 2, 3
      columns.empty? ? small_literal : columns.sample(@random)
    when 4, 5
      small_literal
    when 6, 7
      "(#{expression(columns, depth, level + 1)} #{%w[+ - * / % || & | << >>].sample(@random)} #{expression(columns, depth, level + 1)})"
    when 8
      "CAST(#{expression(columns, depth, level + 1)} AS #{%w[INTEGER REAL TEXT NUMERIC BLOB].sample(@random)})"
    when 9
      function = ["abs", "length", "lower", "upper", "typeof", "quote", "hex", "trim", "ltrim", "rtrim", "unicode", "sign", "round", "octet_length"].sample(@random)
      "#{function}(#{expression(columns, depth, level + 1)})"
    when 10
      function = ["coalesce", "ifnull", "nullif", "max", "min", "instr", "round", "substr", "iif", "concat"].sample(@random)
      arguments = Array.new(function == "iif" ? 3 : 2) { expression(columns, depth, level + 1) }
      "#{function}(#{arguments.join(", ")})"
    when 11
      "CASE WHEN #{condition(columns, depth, level + 1)} THEN #{expression(columns, depth, level + 1)} ELSE #{expression(columns, depth, level + 1)} END"
    when 12
      "CASE #{expression(columns, depth, level + 1)} WHEN #{small_literal} THEN #{small_literal} WHEN #{small_literal} THEN #{expression(columns, depth, level + 1)} END"
    when 13
      "#{expression(columns, depth, level + 1)} COLLATE #{%w[NOCASE BINARY RTRIM].sample(@random)}"
    when 14
      depth < 2 ? "(SELECT #{scalar_subquery(columns, depth)})" : small_literal
    when 15
      "-(#{expression(columns, depth, level + 1)})"
    when 16
      "substr(#{expression(columns, depth, level + 1)}, #{rand(-3..4)}, #{rand(-1..4)})"
    when 17
      "(#{condition(columns, depth, level + 1)})"
    else
      columns.empty? ? small_literal : columns.sample(@random)
    end
  end

  private def scalar_subquery(columns : Array(String), depth : Int32) : String
    table = @list_of_tables.sample(@random)
    alias_name = "q#{depth + 1}"
    inner = visible_columns(table, alias_name)
    term = rand(2) == 0 ? aggregate_call(inner, depth + 1) : inner.sample(@random)
    where = columns.empty? || rand(2) == 0 ? "" : " WHERE #{inner.sample(@random)} = #{columns.sample(@random)}"
    order = term.includes?("(") ? "" : " ORDER BY 1, #{alias_name}.rowid"
    "#{term} FROM #{table.table_name} AS #{alias_name}#{where}#{order} LIMIT 1"
  end

  private def aggregate_call(columns : Array(String), depth : Int32) : String
    argument = columns.empty? ? small_literal : columns.sample(@random)
    case rand(9)
    when 0 then "count(*)"
    when 1 then "count(#{"DISTINCT " if rand(3) == 0}#{argument})"
    when 2 then "sum(#{argument})"
    when 3 then "total(#{argument})"
    when 4 then "avg(#{argument})"
    when 5 then "min(#{argument})"
    when 6 then "max(#{argument})"
    when 7 then "count(#{argument})"
    else        "sum(#{"DISTINCT " if rand(3) == 0}#{argument})"
    end
  end

  private def condition(columns : Array(String), depth : Int32, level : Int32 = 0) : String
    left = expression(columns, depth, level + 1)
    case level > 2 ? rand(2) : rand(14)
    when 0, 1, 2, 3
      "#{left} #{%w[= == != <> < <= > >= IS].sample(@random)} #{expression(columns, depth, level + 1)}"
    when 4
      "#{left} IS #{["NOT ", ""].sample(@random)}NULL"
    when 5
      "#{left} #{["NOT ", ""].sample(@random)}IN (#{Array.new(rand(0..5)) { small_literal }.join(", ")})"
    when 6
      "#{left} #{["NOT ", ""].sample(@random)}BETWEEN #{small_literal} AND #{small_literal}"
    when 7
      pattern = ["'a%'", "'%b%'", "'_bc'", "'A%'", "'%'", "'1%'", "?"].sample(@random)
      @parameters << WORDS.sample(@random) if pattern == "?"
      "#{left} #{["NOT ", ""].sample(@random)}#{%w[LIKE GLOB].sample(@random)} #{pattern}"
    when 8, 9
      "(#{condition(columns, depth, level + 1)} #{%w[AND OR].sample(@random)} #{condition(columns, depth, level + 1)})"
    when 10
      "NOT #{condition(columns, depth, level + 1)}"
    when 11
      return condition(columns, depth, 3) if depth >= 2
      table = @list_of_tables.sample(@random)
      alias_name = "e#{depth + 1}"
      inner = visible_columns(table, alias_name)
      correlated = columns.empty? || rand(2) == 0 ? "" : " WHERE #{inner.sample(@random)} = #{columns.sample(@random)}"
      "#{["NOT ", ""].sample(@random)}EXISTS (SELECT 1 FROM #{table.table_name} AS #{alias_name}#{correlated})"
    when 12
      return condition(columns, depth, 3) if depth >= 2
      table = @list_of_tables.sample(@random)
      alias_name = "n#{depth + 1}"
      inner = visible_columns(table, alias_name)
      "#{left} #{["NOT ", ""].sample(@random)}IN (SELECT #{inner.sample(@random)} FROM #{table.table_name} AS #{alias_name})"
    else
      left
    end
  end
end
