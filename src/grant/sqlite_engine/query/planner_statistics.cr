module Grant::SQLiteEngine::Query
  # What a connection knows from sqlite_stat1 (analyze.c, sqlite3AnalysisLoad
  # and analysisLoader): each table's row estimate and each analyzed
  # index's rows per key prefix, as C's LogEst values (ten times the base-2
  # logarithm).
  class PlannerStatistics
    # nRowLogEst of a table without statistics (about a million rows).
    DEFAULT_TABLE_ESTIMATE = 200_i16

    # The estimates of one analyzed index: the entry count, then the rows
    # an equality on each key prefix leaves.
    record IndexEstimate, list_of_row_estimates : Array(Int16), unordered : Bool

    # Table estimates outlive a reload: sqlite3AnalysisLoad leaves a
    # table without rows in sqlite_stat1 the estimate it had.
    getter table_estimates = {} of String => Int16
    @index_estimates = {} of String => IndexEstimate

    # sqlite3LogEst.
    def self.log_estimate(count : UInt64) : Int16
      return 0_i16 if count < 2
      result = 40
      if count < 8
        while count < 8
          result -= 10
          count <<= 1
        end
      else
        while count > 15
          result += 10
          count >>= 1
        end
      end
      ({0, 2, 3, 5, 6, 7, 8, 9}[count & 7] + result - 10).to_i16
    end

    def self.key(schema_name : String, name : String) : String
      "#{schema_name.downcase}\0#{name.downcase}"
    end

    def self.load(session : Session, carried : Hash(String, Int16)? = nil) : PlannerStatistics
      statistics = new
      statistics.table_estimates.merge!(carried) if carried
      session.list_of_databases.each do |database|
        next if database.page_count == 0
        schema_name = session.schema_name_of(database)
        table = session.write_table(AnalyzePlan::STATISTICS_TABLE, schema_name)
        next unless table && table.list_of_columns.size == 3
        WriteRun.new(session, [] of Value).cursor_rows(table) do |_rowid, row|
          statistics.add(session, schema_name, row[0], row[1], row[2])
        end
        statistics.apply_defaults(session, database, schema_name)
      end
      statistics
    end

    # The row estimate sqlite_stat1 gives *table_name*, or the default.
    def table_estimate(schema_name : String, table_name : String) : Int16
      @table_estimates[PlannerStatistics.key(schema_name, table_name)]? || DEFAULT_TABLE_ESTIMATE
    end

    def index_estimate(schema_name : String, index_name : String) : IndexEstimate?
      @index_estimates[PlannerStatistics.key(schema_name, index_name)]?
    end

    # sqlite3DefaultRowEst: a table with an index that has no statistics
    # counts as a thousand rows at least.
    protected def apply_defaults(session : Session, database : Database, schema_name : String) : Nil
      database.schema.list_of_tables.each do |entry|
        table = session.table(entry.object_name, schema_name)
        next unless table
        next if table.list_of_indexes.all? { |layout| index_estimate(schema_name, layout.entry.object_name) }
        table_key = PlannerStatistics.key(schema_name, table.name)
        @table_estimates[table_key] = 99_i16 if (@table_estimates[table_key]? || DEFAULT_TABLE_ESTIMATE) < 99
      end
    end

    # analysisLoader: a row naming an index of the table gives the index
    # its estimates (and the table its row count unless the index is
    # partial); a row with a NULL or unknown index gives the table's row
    # count. A row named after a WITHOUT ROWID table is its PRIMARY KEY.
    protected def add(session : Session, schema_name : String, table_value : Value, index_value : Value, stat_value : Value) : Nil
      return if table_value.nil? || stat_value.nil?
      table_name = text_of(table_value)
      table = session.table(table_name, schema_name)
      return unless table
      list_of_numbers, unordered = decode(text_of(stat_value))
      table_key = PlannerStatistics.key(schema_name, table.name)
      index_name = index_value.nil? ? nil : text_of(index_value)
      if index_name
        primary_key = table.without_rowid? && index_name.compare(table_name, case_insensitive: true) == 0
        layout = table.list_of_indexes.find { |candidate| candidate.entry.object_name.compare(index_name, case_insensitive: true) == 0 }
        if primary_key || layout
          key_count = layout ? layout.key_count : table.definition.primary_key_positions.size
          list_of_estimates = Array(Int16).new(key_count + 1) { |index| list_of_numbers[index]? || 0_i16 }
          stored_name = layout ? layout.entry.object_name : table.name
          @index_estimates[PlannerStatistics.key(schema_name, stored_name)] = IndexEstimate.new(list_of_estimates, unordered)
          @table_estimates[table_key] = list_of_estimates[0] unless layout && layout.partial?
          return
        end
      end
      @table_estimates[table_key] = list_of_numbers[0]? || 0_i16
    end

    private def text_of(value : Value) : String
      value.is_a?(Bytes) ? String.new(value) : value.to_s
    end

    # decodeIntArray: the leading integers as LogEst values, and whether
    # the words after them include `unordered`.
    private def decode(text : String) : {Array(Int16), Bool}
      list_of_numbers = [] of Int16
      list_of_words = text.split(' ', remove_empty: true)
      position = 0
      while (word = list_of_words[position]?) && word.each_char.all?(&.ascii_number?)
        list_of_numbers << PlannerStatistics.log_estimate(word.to_u64? || UInt64::MAX)
        position += 1
      end
      {list_of_numbers, list_of_words[position..].any?(&.starts_with?("unordered"))}
    end
  end
end
