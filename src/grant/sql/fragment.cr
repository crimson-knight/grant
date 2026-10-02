module Grant::Sql
  # A piece of SQL that Grant splices into a statement verbatim.
  #
  # APIs that accept SQL text (for example the `on_duplicate:` option of
  # `upsert_all`) take only a `Fragment`, never a `String`. That makes trusted
  # SQL visible at the call site and keeps a request parameter from reaching the
  # statement by accident.
  #
  # Build one with `Grant::Sql.fragment`, which accepts only a string literal, so
  # the text is fixed at compile time. Bind user input as data rows instead.
  #
  # ```
  # Product.upsert_all(rows, unique_by: [:sku],
  #   on_duplicate: Grant::Sql.fragment("stock = stock + EXCLUDED.stock"))
  # ```
  struct Fragment
    getter sql : String

    # Prefer `Grant::Sql.fragment`. Calling this with an interpolated or
    # user-supplied string defeats the protection the type exists for.
    def initialize(@sql : String)
    end

    def to_s(io : IO) : Nil
      io << @sql
    end

    def ==(other : Fragment) : Bool
      @sql == other.sql
    end
  end

  # Builds a `Fragment` from a string literal. Anything that is not a literal
  # is rejected at compile time.
  macro fragment(sql)
    {% unless sql.is_a?(StringLiteral) %}
      {% raise "Grant::Sql.fragment takes a string literal; bind runtime values as data instead" %}
    {% end %}
    ::Grant::Sql::Fragment.new({{ sql }})
  end
end
