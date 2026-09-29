module Grant::Query::Assembler
  abstract class Base(Model)
    # Renders *fields* as one WHERE predicate (no `WHERE` keyword) that draws
    # its bind values from this assembler's numbering. `or`, `and`, `not` and
    # `invert_where` use it to fold a set of conditions into a single
    # parenthesized clause; the bind values are in `numbered_parameters`.
    #
    # Calling it twice on one assembler continues the numbering, so two
    # relations rendered for a single `or` never reuse a `$n`.
    def where_group_sql(fields : Array(Grant::Query::WhereField)) : String
      render_where_fields(fields)
    end
  end
end
