module Grant::Query::Assembler
  abstract class Base(Model)
    # True while `where_group_sql` renders a group. Such a group becomes raw
    # SQL on the relation before later chain steps run, so its own-table
    # columns are table-qualified (a `joins` added afterwards cannot make them
    # ambiguous) and a table the association registry knows may be named
    # before it is joined.
    @rendering_where_group : Bool = false

    # Renders *fields* as one WHERE predicate (no `WHERE` keyword) that draws
    # its bind values from this assembler's numbering. `or`, `and`, `not` and
    # `invert_where` use it to fold a set of conditions into a single
    # parenthesized clause; the bind values are in `numbered_parameters`.
    #
    # Calling it twice on one assembler continues the numbering, so two
    # relations rendered for a single `or` never reuse a `$n`.
    def where_group_sql(fields : Array(Grant::Query::WhereField)) : String
      @rendering_where_group = true
      render_where_fields(fields)
    ensure
      @rendering_where_group = false
    end
  end
end
