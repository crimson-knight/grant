require "./builder"

# Validates and quotes a simple field or a table-qualified field. Model-specific
# names and columns arrive as values; the query builder only supplies its
# adapter's identifier quoting operation.
# :nodoc:
module Grant::Query::StructuredFieldResolver
  alias Clause = Grant::Query::JoinSupport::Clause
  alias QuoteIdentifier = Proc(String, String)

  def self.resolve(field : String, model_name : String, model_table : String, model_fields : Array(String), joins : Array(Clause), quote_identifier : QuoteIdentifier) : String
    parts = field.split('.')
    unless parts.size.in?(1..2) && parts.all?(&.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/))
      raise ArgumentError.new("Invalid query field #{field.inspect}")
    end

    column = parts.last
    qualifier = parts.size == 2 ? parts.first : nil
    if qualifier && qualifier != model_table
      # A joined table: check the column against the model behind it when the
      # registry knows one; a raw joined table is only identifier-checked.
      joined = Grant::Query::JoinedColumns.known_column?(model_name, qualifier, column)
      if joined == false
        raise ArgumentError.new("Unknown query field #{column.inspect} for #{model_name}")
      end
    else
      unless model_fields.includes?(column)
        raise ArgumentError.new("Unknown query field #{column.inspect} for #{model_name}")
      end
    end

    if qualifier
      allowed_qualifiers = [model_table] + joins.flat_map { |join| Grant::Query::JoinSupport.qualifiers(join) }
      unless allowed_qualifiers.includes?(qualifier)
        raise ArgumentError.new("Unknown query table #{qualifier.inspect} for #{model_name}")
      end
      "#{quote_identifier.call(qualifier)}.#{quote_identifier.call(column)}"
    elsif !joins.empty?
      "#{quote_identifier.call(model_table)}.#{quote_identifier.call(column)}"
    else
      quote_identifier.call(column)
    end
  end
end
