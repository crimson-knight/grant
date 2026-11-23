module Grant::SQLiteEngine::Query
  # The order a one-pass UPDATE or DELETE visits the rows of a WITHOUT
  # ROWID table. whereLoopAddBtree weighs a full scan of every index of
  # such a table (the condition `!HasRowid(pTab)`), and a secondary index
  # holding every column the statement reads costs rSize + 1 +
  # 15 * szIdxRow / szTabRow, less than the primary key's scan when its
  # entries are narrower; the rows then come in that index's order.
  module WithoutRowidScan
    # The secondary index C scans, or nil for primary key order. Only a
    # WHERE with no index search term is decided here.
    def self.scan_layout(table : WriteTable, where : SQL::Expression?,
                         list_of_read : Array(SQL::Expression)) : IndexLayout?
      info = table.table_info
      return unless info.without_rowid?
      return if where && has_search_term?(where, info)
      read = referenced_columns(info, list_of_read + (where ? [where] : [] of SQL::Expression))
      primary_weight = primary_key_weight(info)
      best = nil
      best_weight = primary_weight
      info.list_of_indexes.reverse_each do |layout|
        next if layout.primary_key? || layout.needs_evaluation?
        held = layout.list_of_key_positions + layout.list_of_tail_positions
        next unless read.all? { |position| held.includes?(position) }
        weight = RowWidth.index_scan_weight(info, layout)
        if weight < best_weight
          best = layout
          best_weight = weight
        end
      end
      best
    end

    # chngPk: an UPDATE that changes the primary key runs in two passes.
    def self.primary_key_changed?(table : WriteTable, list_of_changed : Array(Int32)) : Bool
      info = table.table_info
      info.definition.list_of_primary_key_columns.any? do |name|
        position = info.column_index(name)
        position.nil? || list_of_changed.includes?(position)
      end
    end

    # Sorts *targets* into the order of *layout*'s entries, built from
    # each row as stored (a snapshot holds only the columns the statement
    # reads).
    def self.sort(table : WriteTable, targets : Array({Int64?, Array(Value), Array(Value)}),
                  layout : IndexLayout) : Array({Int64?, Array(Value), Array(Value)})
      comparator = layout.comparator
      keyed = targets.map do |target|
        row = table.database.row_with_key_of(table.layout, target[1]) || target[1]
        {layout.entry_for(row, nil), target}
      end
      keyed.sort! { |left, right| comparator.compare(left[0], right[0]) }
      keyed.map(&.[1])
    end

    # The primary key index holds every column of the table.
    private def self.primary_key_weight(info : TableInfo) : Int32
      sizes = info.definition.list_of_columns.map { |column| RowWidth.column_size(column.declared_type) }
      width = sizes.sum
      (15 * RowWidth.log_est(width.to_u64 * 4)) // RowWidth.log_est((width + 1).to_u64 * 4)
    end

    # A WHERE term an index could search with: a comparison, IN, BETWEEN
    # or NULL test on the first key column of some index.
    private def self.has_search_term?(where : SQL::Expression, info : TableInfo) : Bool
      leading = info.list_of_indexes.compact_map(&.list_of_key_positions.first?).to_set
      conjuncts(where).any? do |term|
        column = case term
                 when SQL::BinaryOperation
                   operator = term.operator
                   next false unless operator.equal? || operator.double_equal? || operator.less? || operator.less_or_equal? ||
                                     operator.greater? || operator.greater_or_equal? || operator.is?
                   column_position(term.left, info) || column_position(term.right, info)
                 when SQL::InList, SQL::Between
                   term.negated ? nil : column_position(term.operand, info)
                 when SQL::NullTest
                   column_position(term.operand, info)
                 end
        !column.nil? && leading.includes?(column)
      end
    end

    private def self.conjuncts(expression : SQL::Expression, into = [] of SQL::Expression) : Array(SQL::Expression)
      if expression.is_a?(SQL::BinaryOperation) && expression.operator.and?
        conjuncts(expression.left, into)
        conjuncts(expression.right, into)
      else
        into << expression
      end
      into
    end

    private def self.column_position(expression : SQL::Expression, info : TableInfo) : Int32?
      return unless expression.is_a?(SQL::ColumnReference)
      info.column_index(expression.column.value)
    end

    # The columns of the table the expressions name (pSrc->colUsed).
    private def self.referenced_columns(info : TableInfo, list_of_expressions : Array(SQL::Expression)) : Array(Int32)
      texts = list_of_expressions.map(&.to_sql)
      info.list_of_column_names.each_index.select do |position|
        name = Regex.escape(info.list_of_column_names[position])
        pattern = Regex.new("(?:^|[^A-Za-z0-9_$])[\"`\\[]?#{name}[\"`\\]]?(?:$|[^A-Za-z0-9_$])", Regex::Options::IGNORE_CASE)
        texts.any? { |text| pattern.matches?(text) }
      end.to_a
    end
  end
end
