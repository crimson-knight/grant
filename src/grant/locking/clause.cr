require "../locking"

module Grant::Locking
  # A vendor lock clause such as `FOR NO KEY UPDATE`, for the cases the
  # `LockMode` enum does not cover. It is appended to the SELECT as written, so
  # it is never built from runtime text: create one with `Grant::Locking.clause`,
  # which only compiles for a string literal or a constant.
  #
  # ```
  # NO_KEY_UPDATE = Grant::Locking.clause("FOR NO KEY UPDATE")
  # User.where(id: 1).lock(NO_KEY_UPDATE).first!
  # ```
  struct Clause
    # Letters, digits, spaces and the punctuation of an `OF table, table` list;
    # no quotes, semicolons, parentheses or comment markers can get through.
    PATTERN = /\A[A-Za-z][A-Za-z0-9_., ]*\z/

    getter sql : String

    # :nodoc: Called by `Grant::Locking.clause`; use that macro instead.
    def self.__from_literal(sql : String) : Clause
      new(sql)
    end

    private def initialize(sql : String)
      unless sql.matches?(PATTERN)
        raise ArgumentError.new("Invalid lock clause #{sql.inspect}: only letters, digits, spaces, underscores, dots and commas are allowed")
      end
      @sql = sql
    end

    def to_s(io : IO) : Nil
      io << @sql
    end
  end

  # Builds a `Clause` from a string literal or a constant. Anything computed at
  # runtime is rejected at compile time.
  macro clause(sql)
    {% unless sql.is_a?(StringLiteral) || sql.is_a?(Path) %}
      {% raise "Grant::Locking.clause takes a string literal or a constant, not #{sql.class_name.id}" %}
    {% end %}
    ::Grant::Locking::Clause.__from_literal({{sql}})
  end
end
