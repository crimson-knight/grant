require "./builder"
require "./sql_expression"

class Grant::Query::Builder(Model)
  # Plucks columns or SQL expressions as typed tuples. Each keyword names a
  # column (or a trusted expression, written as a quoted key) and gives the
  # Crystal type to read it as; the values are read straight off the result set
  # with `rs.read(Type)`, never boxed into `Grant::Columns::Type`. Nullable
  # columns take a nilable type.
  #
  # Respects WHERE, joins, ORDER, LIMIT and IN-list chunking, and a `none`
  # relation returns `[]`. The type must match what the database returns for
  # the expression (`COUNT(*)` is `Int64`).
  #
  # ```
  # User.where(active: true).pluck_as(id: Int64, name: String)
  # # => [{1_i64, "Ada"}, {2_i64, "Grace"}]
  #
  # Order.group(:status).pluck_as(status: String, "COUNT(*)": Int64)
  # Post.joins(:author).pluck_as("authors.name": String)
  # ```
  def pluck_as(**columns : **T) forall T
    {% begin %}
    rows = [] of Tuple({% for key in T.keys %}{{T[key].instance}}, {% end %})
    return rows if is_none?

    if should_chunk_in?
      each_in_chunk do |chunk_query|
        chunk_query.limit!(nil)
        chunk_query.offset!(nil)
        rows.concat(chunk_query.pluck_as_single(**columns))
      end
      return rows
    end

    with_index_hint_fallback { |query| query.pluck_as_single(**columns) }
    {% end %}
  end

  # The first row of `pluck_as`, or `nil` when no row matches.
  #
  # ```
  # User.order(:id).pick_as(id: Int64, name: String) # => {1_i64, "Ada"}
  # ```
  def pick_as(**columns : **T) forall T
    limit(1).pluck_as(**columns).first?
  end

  # Executes one typed pluck (no IN-chunking).
  protected def pluck_as_single(**columns : **T) forall T
    {% begin %}
    names = [{% for key in T.keys %}{{key.stringify}}, {% end %}] of String
    names.each do |name|
      Grant::Query::SqlExpression.validate!(name, "pluck expression") unless Grant::Query::SqlExpression.identifier?(name)
    end

    typed_assembler = assembler
    sql = typed_assembler.pluck_sql(names)
    arguments = typed_assembler.numbered_parameters
    rows = [] of Tuple({% for key in T.keys %}{{T[key].instance}}, {% end %})

    adapter = Model.adapter
    Grant::Logs::SQL.debug { "Typed pluck - #{sql} [#{Model.name}] [args: #{arguments.size}]" }
    adapter.open do |db|
      db.query(sql, args: adapter.normalize_bind_values(arguments)) do |rs|
        rs.each do
          rows << { {% for key in T.keys %}rs.read({{T[key].instance}}), {% end %} }
        end
      end
    end
    rows
    {% end %}
  end
end
