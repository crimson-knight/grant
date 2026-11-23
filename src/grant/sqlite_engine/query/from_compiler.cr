module Grant::SQLiteEngine::Query
  class Compiler
    # One FROM entry with how it joins to the entries before it.
    class JoinStep
      getter entry : FromEntry
      # The source used when no index or rowid path applies.
      getter base_source : RowSource
      getter? left_join : Bool
      getter on : Expr?

      def initialize(@entry : FromEntry, @base_source : RowSource, @left_join : Bool, @on : Expr?)
      end
    end

    # Registers the FROM entries in *context* and returns them in order.
    private def compile_from(from : SQL::From?, context : QueryContext) : Array(JoinStep)
      steps = [] of JoinStep
      return steps unless from
      from.items.each_with_index do |item, position|
        left_join = false
        natural = false
        if join = item.join
          keywords = join.keywords.map(&.upcase)
          raise UnsupportedSQL.new("RIGHT JOIN") if keywords.includes?("RIGHT")
          raise UnsupportedSQL.new("FULL JOIN") if keywords.includes?("FULL")
          left_join = keywords.includes?("LEFT")
          natural = keywords.includes?("NATURAL")
        end
        entry, source = compile_source(item.source, context)
        entry.right_of_left_join = left_join
        on = nil
        using = item.using
        if natural || using
          names = if using
                    using.map(&.value)
                  else
                    entry.list_of_columns.map(&.name).select do |name|
                      context.list_of_entries.any? { |left| left.column_index(name) }
                    end
                  end
          conditions = names.map do |name|
            left = context.list_of_entries.find(&.column_index(name))
            right_index = entry.column_index(name)
            left_index = left.try(&.column_index(name))
            unless left && right_index && left_index
              raise SQLError.new("cannot join using column #{name} - column not present in both tables")
            end
            entry.merged_columns << right_index
            left_expression = left.table.try(&.rowid_alias) == left_index ? rowid_expression(left) : column_expression(left, left_index)
            right_expression = entry.table.try(&.rowid_alias) == right_index ? rowid_expression(entry) : column_expression(entry, right_index)
            ComparisonExpr.new(ComparisonOperator::Equal, left_expression, right_expression).as(Expr)
          end
          on = conditions.reduce { |all, condition| LogicalExpr.new(true, all, condition).as(Expr) } unless conditions.empty?
        end
        context.list_of_entries << entry
        if on_syntax = item.on
          compiled = compile_expression(on_syntax, context)
          on = on ? LogicalExpr.new(true, on, compiled) : compiled
        end
        steps << JoinStep.new(entry, source, left_join, on)
      end
      steps
    end

    # The entry and source for one FROM item.
    private def compile_source(source : SQL::TableSource, context : QueryContext) : {FromEntry, RowSource}
      case source
      when SQL::TableReference then compile_table_reference(source, context)
      when SQL::SubquerySource
        plan = compile_from_subquery(source.query, context)
        slot = allocate_slot
        name = source.alias_name.try(&.value) || "(subquery-#{slot})"
        entry = FromEntry.new(name, slot, subquery_columns(plan, nil), nil)
        {entry, MaterializedSource.new(slot, plan.producer, !plan.outer_slots.empty?).as(RowSource)}
      when SQL::TableFunction
        compile_table_function(source, context)
      else
        raise UnsupportedSQL.new("parenthesized join in FROM")
      end
    end

    private def compile_from_subquery(query : SQL::SelectStatement, context : QueryContext) : QueryPlan
      plan = compile_query(query, context.parent, context.ctes)
      plan.outer_slots.each do |slot|
        next if context.owns_slot?(slot)
        context.correlated = true
        context.outer_slots << slot
      end
      plan
    end

    # sqlite3ColumnsFromExprList: the columns a subquery, view or CTE
    # offers, named by *names* when given.
    private def subquery_columns(plan : QueryPlan, names : Array(String)?) : Array(SourceColumn)
      width = plan.list_of_column_names.size
      if names && names.size != width
        raise SQLError.new("expected #{names.size} columns but got #{width}")
      end
      chosen = names || unique_names(plan)
      (0...width).map do |index|
        SourceColumn.new(chosen[index], plan.list_of_column_affinities[index], plan.list_of_collations[index],
          realify: !plan.flattened)
      end
    end

    private def unique_names(plan : QueryPlan) : Array(String)
      Compiler.unique_names(plan.list_of_subquery_names || plan.list_of_column_names)
    end

    # sqlite3ColumnsFromExprList: "true" and "false" become columnN, and a
    # repeated name gets ":N".
    def self.unique_names(list_of_names : Array(String)) : Array(String)
      used = Set(String).new
      list_of_names.map_with_index do |name, index|
        name = "column#{index + 1}" if name.compare("true", case_insensitive: true) == 0 || name.compare("false", case_insensitive: true) == 0
        candidate = name
        count = 0
        while used.includes?(candidate.downcase)
          base = candidate
          if colon = base.rindex(':')
            base = base[0, colon] if colon > 0 && base[colon + 1..].each_char.all?(&.ascii_number?) && !base[colon + 1..].empty?
          end
          count += 1
          candidate = "#{base}:#{count}"
        end
        used << candidate.downcase
        candidate
      end
    end

    private def compile_table_reference(reference : SQL::TableReference, context : QueryContext) : {FromEntry, RowSource}
      name = reference.name.value
      alias_name = reference.alias_name.try(&.value) || name
      schema = reference.schema.try(&.value)
      if schema.nil?
        if (recursive = @recursive_source) && @recursive_name.try(&.compare(name, case_insensitive: true)) == 0
          queue_source, _slot, columns = recursive
          slot = allocate_slot
          queue_row = QueueRowSource.new(slot)
          # The recursive step reads the shared queue row through its own slot.
          linked = LinkedQueueSource.new(queue_source, queue_row)
          return {FromEntry.new(alias_name, slot, columns, nil), linked.as(RowSource)}
        end
        if definition = context.ctes.try(&.find(name))
          plan = compile_cte(definition, context)
          slot = allocate_slot
          entry = FromEntry.new(alias_name, slot, subquery_columns(plan, definition.list_of_column_names), nil)
          return {entry, MaterializedSource.new(slot, plan.producer, !plan.outer_slots.empty?).as(RowSource)}
        end
      end
      if schema && !schema.compare("main", case_insensitive: true).zero?
        if schema.compare("temp", case_insensitive: true).zero?
          raise SQLError.new("no such table: #{schema}.#{name}")
        end
        raise SQLError.new("no such table: #{schema}.#{name}")
      end
      if view = @session.view(name)
        plan = compile_view(view)
        slot = allocate_slot
        entry = FromEntry.new(alias_name, slot, subquery_columns(plan, view.list_of_column_names), nil)
        return {entry, MaterializedSource.new(slot, plan.producer, false).as(RowSource)}
      end
      table = @session.table(name)
      # An eponymous table-valued function (pragma_database_list) named
      # without arguments reads as a table.
      if table.nil? && Catalog::COLUMNS.has_key?(name.downcase)
        return catalog_source(name, alias_name, [] of Expr)
      end
      unless table
        full = schema ? "#{schema}.#{name}" : name
        raise SQLError.new("no such table: #{full}")
      end
      slot = allocate_slot
      columns = (0...table.list_of_column_names.size).map do |index|
        SourceColumn.new(table.list_of_column_names[index], table.list_of_affinities[index], table.list_of_collations[index])
      end
      entry = FromEntry.new(alias_name, slot, columns, table)
      if indexed_by = reference.indexed_by
        unless table.list_of_indexes.any? { |index| index.entry.object_name.compare(indexed_by.value, case_insensitive: true) == 0 }
          raise SQLError.new("no such index: #{indexed_by.value}")
        end
        entry.indexed_by = indexed_by.value
      end
      entry.not_indexed = reference.not_indexed
      {entry, TableScanSource.new(@session.database, table, slot).as(RowSource)}
    end

    # A CTE's body, compiled once per reference. A recursive CTE whose body
    # names itself runs through RecursiveProducer.
    private def compile_cte(definition : CteDefinition, context : QueryContext) : QueryPlan
      query = definition.query
      if definition.recursive? && refers_to?(query, definition.name)
        return compile_recursive(definition, context)
      end
      scope = definition.enclosing
      # Inside its own body a non-recursive CTE does not see itself.
      if scope
        inner = CteScope.new(scope.parent)
        scope.list_of_definitions.each do |other|
          break if other.same?(definition)
          inner.list_of_definitions << other
        end
        scope = inner
      end
      plan = compile_query(query, context.parent, scope)
      plan.outer_slots.each do |slot|
        next if context.owns_slot?(slot)
        context.correlated = true
        context.outer_slots << slot
      end
      plan
    end

    # True when *query* names *name* as a table anywhere in its FROM
    # clauses (including subqueries).
    private def refers_to?(query : SQL::SelectStatement, name : String) : Bool
      query.cores.any? do |core|
        next false unless core.is_a?(SQL::SelectClause)
        from = core.from
        next false unless from
        from.items.any? { |item| source_refers_to?(item.source, name) }
      end
    end

    private def source_refers_to?(source : SQL::TableSource, name : String) : Bool
      case source
      when SQL::TableReference then source.schema.nil? && source.name.value.compare(name, case_insensitive: true) == 0
      when SQL::SubquerySource then refers_to?(source.query, name)
      when SQL::NestedJoin     then source.from.items.any? { |item| source_refers_to?(item.source, name) }
      else                          false
      end
    end

    private def compile_recursive(definition : CteDefinition, context : QueryContext) : QueryPlan
      query = definition.query
      name = definition.name
      split = query.cores.index { |core| core_refers_to?(core, name) } || query.cores.size
      if split == 0
        raise SQLError.new("circular reference: #{name}")
      end
      if split == query.cores.size
        return compile_query(query, context.parent, definition.enclosing)
      end
      operator = query.operators[split - 1]
      unless operator.union? || operator.union_all?
        raise SQLError.new("recursive aggregate queries not supported")
      end
      initial = SQL::SelectStatement.new(nil, query.cores[0, split], query.operators[0, split - 1], [] of SQL::OrderingTerm, nil)
      initial_plan = compile_query(initial, context.parent, definition.enclosing)
      columns = subquery_columns(initial_plan, definition.list_of_column_names)
      queue_row = QueueRowSource.new(-1)
      recursive_cores = query.cores[split..]
      recursive_operators = query.operators[split..]
      recursive_query = SQL::SelectStatement.new(nil, recursive_cores, recursive_operators, [] of SQL::OrderingTerm, nil)
      recursive_context = QueryContext.new(context.parent, @slot_count, definition.enclosing)
      saved_name = @recursive_name
      saved_source = @recursive_source
      @recursive_name = name
      @recursive_source = {queue_row, -1, columns}
      recursive_plan = compile_query(recursive_query, context.parent, definition.enclosing)
      @recursive_name = saved_name
      @recursive_source = saved_source
      if recursive_plan.list_of_column_names.size != columns.size
        raise SQLError.new("SELECTs to the left and right of UNION do not have the same number of result columns")
      end
      order_keys = query.order_by.map do |term|
        position = integer_term(term.expression, columns.size, "ORDER")
        if position.nil? && (reference = term.expression).is_a?(SQL::ColumnReference)
          position = columns.index { |column| column.name.compare(reference.column.value, case_insensitive: true) == 0 }
        end
        raise UnsupportedSQL.new("ORDER BY expression in a recursive CTE") unless position
        sort_key(term, position, columns[position].collation)
      end
      limit = query.limit
      limit_expression = limit.try do |clause|
        comma_count = clause.comma_form ? clause.offset : nil
        compile_expression(comma_count || clause.count, recursive_context)
      end
      offset_expression = limit.try { |clause| (clause.comma_form ? clause.count : clause.offset).try { |expression| compile_expression(expression, recursive_context) } }
      offset_expression = nil if limit && limit.comma_form && limit.offset.nil?
      producer = RecursiveProducer.new(initial_plan.producer, recursive_plan.producer, queue_row, operator.union_all?,
        columns.map(&.collation), order_keys, limit_expression, offset_expression, RECURSIVE_ROW_BUDGET)
      outer = initial_plan.outer_slots | recursive_plan.outer_slots
      QueryPlan.new(producer, columns.map(&.name), initial_plan.list_of_first_core_columns, columns.map(&.collation),
        columns.map(&.affinity), outer, columns.map(&.affinity))
    end

    private def core_refers_to?(core : SQL::SelectCore, name : String) : Bool
      return false unless core.is_a?(SQL::SelectClause)
      from = core.from
      return false unless from
      from.items.any? { |item| source_refers_to?(item.source, name) }
    end

    @recursive_name : String? = nil
    @recursive_source : {QueueRowSource, Int32, Array(SourceColumn)}? = nil

    private def compile_view(view : ViewInfo) : QueryPlan
      compile_query(view.query, nil, nil)
    end

    private def compile_table_function(source : SQL::TableFunction, context : QueryContext) : {FromEntry, RowSource}
      arguments = source.arguments.map { |argument| compile_expression(argument, context) }
      catalog_source(source.name.value, source.alias_name.try(&.value) || source.name.value, arguments)
    end

    private def catalog_source(display_name : String, alias_name : String, arguments : Array(Expr)) : {FromEntry, RowSource}
      name = display_name.downcase
      producer = Catalog.function_producer(name, arguments, @session) || raise SQLError.new("no such table: #{display_name}")
      slot = allocate_slot
      columns = Catalog.function_columns(name).map { |column_name| SourceColumn.new(column_name, ExpressionAffinity::Blob, Collation::Binary) }
      correlated = arguments.any? { |argument| !argument.constant? }
      {FromEntry.new(alias_name, slot, columns, nil), MaterializedSource.new(slot, producer, correlated).as(RowSource)}
    end
  end

  # The recursive step's view of the queue row: copies the row the
  # RecursiveProducer set into this reference's own slot.
  class LinkedQueueSource < RowSource
    def initialize(@shared : QueueRowSource, @own : QueueRowSource)
    end

    def open(frame : Frame) : Nil
      @own.current = @shared.current
      @own.open(frame)
    end

    def advance(frame : Frame) : Bool
      @own.advance(frame)
    end
  end
end
