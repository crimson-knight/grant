module Grant::SQLiteEngine::Query
  class Compiler
    # One FROM entry with how it joins to the entries before it.
    class JoinStep
      getter entry : FromEntry
      # The source used when no index or rowid path applies.
      getter base_source : RowSource
      getter? left_join : Bool
      property on : Expr?
      # The ON clause, compiled after WHERE (sqlite3ProcessJoin ANDs it onto
      # the end of WHERE before names are resolved).
      getter on_syntax : SQL::Expression?

      def initialize(@entry : FromEntry, @base_source : RowSource, @left_join : Bool, @on : Expr?,
                     @on_syntax : SQL::Expression? = nil)
      end
    end

    # Registers the FROM entries in *context* and returns them in order.
    private def compile_from(from : SQL::From?, context : QueryContext) : Array(JoinStep)
      steps = [] of JoinStep
      return steps unless from
      from.items.each do |item|
        left_join = false
        natural = false
        if join = item.join
          keywords = join.keywords.map(&.upcase)
          raise UnsupportedSQL.new("RIGHT JOIN") if keywords.includes?("RIGHT")
          raise UnsupportedSQL.new("FULL JOIN") if keywords.includes?("FULL")
          left_join = keywords.includes?("LEFT")
          natural = keywords.includes?("NATURAL")
        end
        if natural && (item.on || item.using)
          raise SQLError.new("a NATURAL join may not have an ON or USING clause")
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
                      context.list_of_entries.any?(&.column_index(name))
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
        steps << JoinStep.new(entry, source, left_join, on, item.on)
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

    # Compiles each step's ON clause as the tail of WHERE: every FROM entry
    # is visible; a LEFT JOIN ON naming a table to its right is an error.
    private def compile_join_conditions(steps : Array(JoinStep), context : QueryContext) : Nil
      steps.each_with_index do |step, index|
        syntax = step.on_syntax
        next unless syntax
        compiled = resolve_expression(syntax, context)
        later = steps[(index + 1)..].map(&.entry.slot).to_set
        if step.left_join? && !(ExpressionWalk.slots(compiled) & later).empty?
          raise SQLError.new("ON clause references tables to its right")
        end
        existing = step.on
        step.on = existing ? LogicalExpr.new(true, existing, compiled) : compiled
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
    private def subquery_columns(plan : QueryPlan, names : Array(String)?, cte_name : String? = nil,
                                 view_name : String? = nil) : Array(SourceColumn)
      width = plan.list_of_column_names.size
      if names && names.size != width
        # withExpand and sqlite3ViewGetColumnNames word it differently.
        raise SQLError.new("table #{cte_name} has #{width} values for #{names.size} columns") if cte_name
        raise SQLError.new("expected #{names.size} columns for '#{view_name}' but got #{width}") if view_name
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
          # withExpand: the recursive step may name the CTE only in its own
          # FROM, not from a subquery inside it.
          raise SQLError.new("multiple recursive references: #{name}") unless @query_depth == @recursive_depth
          slot = allocate_slot
          queue_row = QueueRowSource.new(slot)
          # The recursive step reads the shared queue row through its own slot.
          linked = LinkedQueueSource.new(queue_source, queue_row)
          return {FromEntry.new(alias_name, slot, columns, nil), linked.as(RowSource)}
        end
        if definition = context.ctes.try(&.find(name))
          if error = @list_of_cte_errors.find { |(expanding, _)| expanding.same?(definition) }
            raise SQLError.new("#{error[1]}: #{definition.name}")
          end
          plan = compile_cte(definition, context)
          slot = allocate_slot
          entry = FromEntry.new(alias_name, slot, subquery_columns(plan, definition.list_of_column_names, cte_name: definition.name), nil)
          return {entry, MaterializedSource.new(slot, plan.producer, !plan.outer_slots.empty?).as(RowSource)}
        end
      end
      if schema && !@session.schema?(schema)
        raise SQLError.new("no such table: #{schema}.#{name}")
      end
      main_schema = schema.nil? || schema.compare("main", case_insensitive: true).zero?
      if main_schema && (view = @session.view(name))
        plan = compile_view(view)
        slot = allocate_slot
        entry = FromEntry.new(alias_name, slot, subquery_columns(plan, view.list_of_column_names, view_name: name), nil)
        return {entry, MaterializedSource.new(slot, plan.producer, false).as(RowSource)}
      end
      table = @session.table(name, schema)
      # An eponymous table-valued function (pragma_database_list) named
      # without arguments reads as a table.
      if table.nil? && (Catalog::COLUMNS.has_key?(name.downcase) || name.downcase.in?("json_each", "json_tree"))
        return catalog_source(name, alias_name, [] of Expr)
      end
      unless table
        # A view's body names its tables in the view's own schema.
        full = schema ? "#{schema}.#{name}" : (@view_depth > 0 ? "main.#{name}" : name)
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
      {entry, TableScanSource.new(table.database, table, slot).as(RowSource)}
    end

    # A CTE's body, compiled once per reference. A recursive CTE whose body
    # names itself runs through RecursiveProducer.
    private def compile_cte(definition : CteDefinition, context : QueryContext) : QueryPlan
      query = definition.query
      # SQLite treats a CTE whose FROM names itself as recursive whether or
      # not the WITH says RECURSIVE (withExpand).
      if query.cores.any? { |core| core_refers_to?(core, definition.name) }
        return compile_recursive(definition, context)
      end
      # Any other reference to itself from its own body is circular.
      plan = with_cte_error(definition, "circular reference") do
        compile_query(query, context.parent, definition.enclosing)
      end
      plan.outer_slots.each do |slot|
        next if context.owns_slot?(slot)
        context.correlated = true
        context.outer_slots << slot
      end
      plan
    end

    @list_of_cte_errors = [] of {CteDefinition, String}
    @recursive_depth = 0

    # Compiles with references to *definition* raising *message* (the
    # zCteErr withExpand sets while it expands a CTE's own body).
    private def with_cte_error(definition : CteDefinition, message : String, &)
      @list_of_cte_errors << {definition, message}
      begin
        yield
      ensure
        @list_of_cte_errors.pop
      end
    end

    # True when a FROM item of the core (not a subquery) names *name*.
    private def source_refers_to?(source : SQL::TableSource, name : String) : Bool
      case source
      when SQL::TableReference then source.schema.nil? && source.name.value.compare(name, case_insensitive: true) == 0
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
      operator = query.operators[split - 1]
      unless operator.union? || operator.union_all?
        raise SQLError.new("recursive aggregate queries not supported")
      end
      initial = SQL::SelectStatement.new(nil, query.cores[0, split], query.operators[0, split - 1], [] of SQL::OrderingTerm, nil)
      initial_plan = with_cte_error(definition, "circular reference") do
        compile_query(initial, context.parent, definition.enclosing)
      end
      columns = subquery_columns(initial_plan, definition.list_of_column_names, cte_name: definition.name)
      queue_row = QueueRowSource.new(-1)
      recursive_cores = query.cores[split..]
      recursive_operators = query.operators[split..]
      recursive_query = SQL::SelectStatement.new(nil, recursive_cores, recursive_operators, [] of SQL::OrderingTerm, nil)
      recursive_context = QueryContext.new(context.parent, @slot_count, definition.enclosing)
      saved_name = @recursive_name
      saved_source = @recursive_source
      saved_depth = @recursive_depth
      @recursive_name = name
      @recursive_source = {queue_row, -1, columns}
      @recursive_depth = @query_depth + 1
      begin
        recursive_plan = with_cte_error(definition, "multiple recursive references") do
          compile_query(recursive_query, context.parent, definition.enclosing)
        end
      ensure
        @recursive_name = saved_name
        @recursive_source = saved_source
        @recursive_depth = saved_depth
      end
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
      limit_expression = limit.try { |clause| compile_expression(clause.count, recursive_context) }
      offset_expression = limit.try(&.offset).try { |expression| compile_expression(expression, recursive_context) }
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

    @view_depth = 0

    private def compile_view(view : ViewInfo) : QueryPlan
      @view_depth += 1
      begin
        compile_query(view.query, nil, nil)
      ensure
        @view_depth -= 1
      end
    end

    private def compile_table_function(source : SQL::TableFunction, context : QueryContext) : {FromEntry, RowSource}
      arguments = source.arguments.map { |argument| compile_expression(argument, context) }
      catalog_source(source.name.value, source.alias_name.try(&.value) || source.name.value, arguments)
    end

    private def catalog_source(display_name : String, alias_name : String, arguments : Array(Expr)) : {FromEntry, RowSource}
      name = display_name.downcase
      if name.in?("json_each", "json_tree")
        if arguments.size > 2
          raise SQLError.new("too many arguments on #{display_name}() - max 2")
        end
        slot = allocate_slot
        columns = JsonEachProducer::COLUMNS.map { |column_name| SourceColumn.new(column_name, ExpressionAffinity::Blob, Collation::Binary) }
        correlated = arguments.any? { |argument| !argument.constant? }
        producer = JsonEachProducer.new(arguments, recursive: name == "json_tree")
        return {FromEntry.new(alias_name, slot, columns, nil), MaterializedSource.new(slot, producer, correlated).as(RowSource)}
      end
      raise UnsupportedSQL.new("JSON table function #{display_name} (milestone G6)") if name.in?("jsonb_each", "jsonb_tree")
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
