# Renders WHERE predicates for the assemblers. Nothing here depends on the
# model type: the assembler passes in the model's name, table, columns, and how
# to quote identifiers and bind parameters, so one copy of this code serves every model and SQL
# dialect instead of one per `Assembler::Base(Model)` instantiation.
class Grant::Query::Assembler::PredicateRenderer
  OPERATORS = {"eq": "=", "gteq": ">=", "lteq": "<=", "neq": "!=", "ltgt": "<>", "gt": ">", "lt": "<", "ngt": "!>", "nlt": "!<", "in": "IN", "nin": "NOT IN", "like": "LIKE", "nlike": "NOT LIKE"}

  # Equality-style operators are the only ones that mean anything on
  # ciphertext; a range or LIKE would compare encrypted bytes and silently
  # match the wrong rows.
  ENCRYPTED_QUERY_OPERATORS = {:eq, :neq, :ltgt, :in, :nin}

  # True while a grouped condition renders (see `Assembler::Base#where_group_sql`).
  property rendering_where_group : Bool = false
  property join_clauses : Array(NamedTuple(type: Symbol, table: String, on: String))

  # Binds one value and returns its placeholder (`?`, `$1`), like the
  # assembler's `add_parameter`.
  alias BindParameter = Proc(Grant::Columns::Type, String)

  # Records a column the predicate references, like `add_aggregate_field`.
  alias RecordField = Proc(String, Nil)

  # Quotes one identifier, like `Model.quote`. It is called only when a
  # predicate names a column, so rendering a raw statement never resolves the
  # model's adapter (a sharded model has none outside a shard context).
  alias QuoteIdentifier = Proc(String, String)

  def initialize(@model_name : String, @table_name : String, @fields : Array(String),
                 @quote_identifier : QuoteIdentifier, @bind_parameter : BindParameter,
                 @record_field : RecordField,
                 @join_clauses : Array(NamedTuple(type: Symbol, table: String, on: String)))
  end

  def sql_operator(operator : Symbol) : String
    OPERATORS[operator.to_s]? || operator.to_s
  end

  def render_where_fields(fields : Array(Grant::Query::WhereField)) : String
    String.build do |sql|
      fields.each_with_index do |expression, index|
        sql << " #{expression[:join].to_s.upcase} " unless index == 0

        if expression[:field]?.nil?
          clause = case expression
                   when NamedTuple(join: Symbol, stmt: String, values: Array(Grant::Columns::Type))
                     bind_raw_statement(expression[:stmt], expression[:values])
                   else
                     expr = expression.as(NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type))
                     value = expr[:value]
                     bind_raw_statement(expr[:stmt], value.nil? ? [] of Grant::Columns::Type : [value])
                   end
          sql << clause
        else
          expr = expression.as(NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type))
          field = structured_field_sql(expr[:field])
          @record_field.call(field)

          operator = expr[:operator]
          value = encrypted_query_value(expr[:field], operator, expr[:value])
          # A single value that matches its ciphertext and its plaintext (while
          # unencrypted data is still supported) becomes an IN / NOT IN list.
          if value.is_a?(Array) && !expr[:value].is_a?(Array)
            operator = :in if operator == :eq
            operator = :nin if operator.in?(:neq, :ltgt)
          end
          if value.nil?
            case operator
            when :eq
              sql << "#{field} IS NULL"
            when :neq, :ltgt
              sql << "#{field} IS NOT NULL"
            else
              raise ArgumentError.new("Operator #{operator.inspect} does not support nil values")
            end
          else
            if value.is_a?(Array)
              array = value.as(Array)
              if array.empty?
                sql << (operator == :nin ? "1=1" : "1=0")
              else
                placeholders = array.map { |item| @bind_parameter.call(item.as(Grant::Columns::Type)) }
                sql << "#{field} #{sql_operator(operator)} (#{placeholders.join(",")})"
              end
            else
              sql << "#{field} #{sql_operator(operator)} #{@bind_parameter.call(value)}"
            end
          end
        end
      end
    end
  end

  def structured_field_sql(field : String) : String
    parts = field.split('.')
    unless parts.size.in?(1..2) && parts.all?(&.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/))
      raise ArgumentError.new("Invalid query field #{field.inspect}")
    end

    column = parts.last
    qualifier = parts.first if parts.size == 2
    encrypted_attribute = if qualifier.nil? || qualifier == @table_name
                            Grant::Encryption::EncryptedAttributeRegistry.lookup(@model_name, column)
                          end
    valid_column = if qualifier.nil? || qualifier == @table_name
                     @fields.includes?(column) || !encrypted_attribute.nil?
                   elsif Grant::Query::JoinSupport.joins?(@join_clauses, qualifier)
                     # The model behind the joined table decides. A nested join,
                     # a through table, an alias or a raw joined table the
                     # registry does not know is a validated identifier, quoted
                     # below.
                     Grant::Query::JoinedColumns.known_column?(@model_name, qualifier, column) != false
                   elsif @rendering_where_group
                     # A grouped condition is rendered when it is added, so the
                     # `joins` for a registry-known table may still follow.
                     Grant::Query::JoinedColumns.known_column?(@model_name, qualifier, column) == true
                   else
                     false
                   end

    unless valid_column
      raise ArgumentError.new("Unknown query field #{field.inspect} for #{@model_name}")
    end

    column_name = encrypted_attribute.try(&.column_name) || column

    if qualifier
      "#{@quote_identifier.call(qualifier)}.#{@quote_identifier.call(column_name)}"
    elsif !@join_clauses.empty? || @rendering_where_group
      "#{@quote_identifier.call(@table_name)}.#{@quote_identifier.call(column_name)}"
    else
      @quote_identifier.call(column_name)
    end
  end

  private def encrypted_query_value(field : String, operator : Symbol, value : Grant::Columns::Type) : Grant::Columns::Type
    parts = field.split('.')
    return value unless parts.size == 1 || parts.first == @table_name

    attribute_name = parts.last
    encrypted_attribute = Grant::Encryption::EncryptedAttributeRegistry.lookup(@model_name, attribute_name)
    return value unless encrypted_attribute
    unless encrypted_attribute.deterministic
      raise ArgumentError.new("Cannot query non-deterministic encrypted field: #{attribute_name}")
    end
    unless ENCRYPTED_QUERY_OPERATORS.includes?(operator)
      raise ArgumentError.new("Encrypted field #{attribute_name.inspect} supports only equality and IN comparisons, not #{operator.inspect}")
    end

    Grant::Encryption::QueryValue.rewrite(encrypted_attribute, value)
  end

  # Rewrites raw-clause placeholders to this assembler's local bind numbering
  # and rejects mismatched argument counts before the driver sees the SQL.
  def bind_raw_statement(statement : String, values : Array(Grant::Columns::Type)) : String
    output = String::Builder.new
    chars = statement.chars
    dollar_tokens = {} of Int32 => String
    dollar_indices = [] of Int32
    question_count = 0
    dollar_style = false
    index = 0
    quote : Char? = nil

    while index < chars.size
      char = chars[index]

      if current_quote = quote
        output << char
        if char == current_quote
          if index + 1 < chars.size && chars[index + 1] == current_quote
            output << chars[index + 1]
            index += 1
          else
            quote = nil
          end
        elsif char == '\\' && index + 1 < chars.size
          output << chars[index + 1]
          index += 1
        end
      elsif char == '\'' || char == '"'
        quote = char
        output << char
      elsif char == '-' && index + 1 < chars.size && chars[index + 1] == '-'
        output << char << chars[index + 1]
        index += 1
        while index + 1 < chars.size && chars[index + 1] != '\n'
          output << chars[index + 1]
          index += 1
        end
      elsif char == '/' && index + 1 < chars.size && chars[index + 1] == '*'
        output << char << chars[index + 1]
        index += 1
        while index + 1 < chars.size
          index += 1
          output << chars[index]
          break if chars[index - 1] == '*' && chars[index] == '/'
        end
      elsif char == '?' && index + 1 < chars.size && chars[index + 1] == '?'
        # `??` is the escape for a literal `?` (PostgreSQL's JSONB `?`, `?|`
        # and `?&` operators), matching `Adapter::Base#ensure_clause_template`.
        output << '?'
        index += 1
      elsif char == '?'
        raise ArgumentError.new("Do not mix ? and numbered placeholders in one query clause") if dollar_style
        raise ArgumentError.new("Raw query placeholder count does not match bind values") if question_count >= values.size
        output << @bind_parameter.call(values[question_count])
        question_count += 1
      elsif char == '$' && index + 1 < chars.size && chars[index + 1].number?
        raise ArgumentError.new("Do not mix ? and numbered placeholders in one query clause") if question_count > 0
        dollar_style = true
        number_start = index + 1
        number_end = number_start
        while number_end < chars.size && chars[number_end].number?
          number_end += 1
        end
        parameter_index = chars[number_start...number_end].join.to_i
        unless parameter_index.in?(1..values.size)
          raise ArgumentError.new("Raw query placeholder count does not match bind values")
        end
        dollar_indices << parameter_index unless dollar_indices.includes?(parameter_index)
        token = dollar_tokens[parameter_index] ||= @bind_parameter.call(values[parameter_index - 1])
        output << token
        index = number_end - 1
      else
        output << char
      end

      index += 1
    end

    if dollar_style
      unless dollar_indices.size == values.size && values.size.times.all? { |number| dollar_indices.includes?(number + 1) }
        raise ArgumentError.new("Raw query placeholder count does not match bind values")
      end
    elsif question_count != values.size
      raise ArgumentError.new("Raw query placeholder count does not match bind values")
    end

    output.to_s
  end
end
