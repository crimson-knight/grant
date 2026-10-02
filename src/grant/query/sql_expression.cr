# Checks for raw SQL fragments that developers pass to relation methods such as
# `order("lower(name) DESC")`, `group("date(created_at)")` or
# `select("COUNT(*) AS n")`.
#
# The fragment is trusted the way ActiveRecord trusts `Arel.sql`: it is placed
# in the statement as written. Validation only rejects what could never belong
# to a single expression, so a string that reaches the relation by mistake
# cannot end the clause and append another statement.
module Grant::Query::SqlExpression
  # Returns the stripped *sql* when it is a single balanced expression.
  #
  # Raises `ArgumentError` for a blank fragment, a statement separator, a comment
  # opener or terminator outside a quoted literal, an unterminated quote, or
  # unbalanced parentheses. *kind* names the clause in the error message.
  def self.validate!(sql : String, kind : String = "SQL expression") : String
    stripped = sql.strip
    raise ArgumentError.new("#{kind} cannot be blank") if stripped.empty?

    chars = stripped.chars
    quote : Char? = nil
    depth = 0
    index = 0
    while index < chars.size
      char = chars[index]
      following = chars[index + 1]?
      if current = quote
        # A doubled quote character stays inside the literal.
        if char == current
          if following == current
            index += 1
          else
            quote = nil
          end
        end
      elsif char == '\'' || char == '"' || char == '`'
        quote = char
      elsif char == ';'
        raise ArgumentError.new("#{kind} cannot contain a statement separator: #{stripped.inspect}")
      elsif (char == '-' && following == '-') || (char == '/' && following == '*') || (char == '*' && following == '/')
        raise ArgumentError.new("#{kind} cannot contain a comment marker: #{stripped.inspect}")
      elsif char == '('
        depth += 1
      elsif char == ')'
        depth -= 1
        raise ArgumentError.new("#{kind} has unbalanced parentheses: #{stripped.inspect}") if depth < 0
      end
      index += 1
    end

    raise ArgumentError.new("#{kind} has an unterminated quote: #{stripped.inspect}") if quote
    raise ArgumentError.new("#{kind} has unbalanced parentheses: #{stripped.inspect}") unless depth == 0

    stripped
  end

  # Splits *sql* on commas that are not inside parentheses or quoted literals,
  # so `"a DESC, lower(b, c)"` yields two terms.
  def self.split_terms(sql : String) : Array(String)
    terms = [] of String
    current = String::Builder.new
    depth = 0
    quote : Char? = nil
    sql.each_char do |char|
      if current_quote = quote
        quote = nil if char == current_quote
        current << char
      elsif char == '\'' || char == '"' || char == '`'
        quote = char
        current << char
      elsif char == '('
        depth += 1
        current << char
      elsif char == ')'
        depth -= 1
        current << char
      elsif char == ',' && depth == 0
        terms << current.to_s.strip
        current = String::Builder.new
      else
        current << char
      end
    end
    terms << current.to_s.strip
    terms.reject(&.empty?)
  end

  # `true` when *text* is a column name or a `table.column` pair.
  #
  # See also `.column_function?`.
  def self.identifier?(text : String) : Bool
    text.matches?(/\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?\z/)
  end
end

module Grant::Query::SqlExpression
  # A SQL fragment the developer vouches for, as ActiveRecord's `Arel.sql`
  # does. Build one with `Grant.sql`. Methods that otherwise accept only
  # column-shaped strings, such as `order`, accept it as written (after the
  # single-expression check in `SqlExpression.validate!`).
  record Trusted, sql : String

  COLUMN_REFERENCE = /[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?/
  COLUMN_FUNCTION  = /\A\s*[A-Za-z_][A-Za-z0-9_]*\(\s*(?:#{COLUMN_REFERENCE}(?:\s*,\s*#{COLUMN_REFERENCE})*)?\s*\)(?:\s+(?:asc|desc))?(?:\s+nulls\s+(?:first|last))?\s*\z/i

  # `true` when *text* is a function applied to column references only, with an
  # optional direction and NULL placement, such as `lower(name) DESC` or
  # `coalesce(name, nickname)`. This is the raw ORDER BY shape ActiveRecord
  # accepts without `Arel.sql`: it can carry no literal, operator or subquery,
  # so a sort parameter from a request cannot smuggle SQL through it.
  def self.column_function?(text : String) : Bool
    text.matches?(COLUMN_FUNCTION)
  end
end

module Grant
  # Marks *fragment* as trusted SQL for relation methods that otherwise accept
  # only column-shaped strings, like ActiveRecord's `Arel.sql`. Never pass
  # request input through it.
  #
  # ```
  # Post.order(Grant.sql("CASE WHEN pinned THEN 0 ELSE 1 END, created_at DESC"))
  # ```
  def self.sql(fragment : String) : Grant::Query::SqlExpression::Trusted
    Grant::Query::SqlExpression::Trusted.new(fragment)
  end
end
