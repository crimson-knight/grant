module Grant::Query
  # Provides chainable where methods for more expressive queries.
  #
  # Access the WhereChain by calling `where` without arguments:
  # ```
  # User.where.like(:email, "%@gmail.com")
  # User.where.gt(:age, 18).lt(:age, 65)
  # ```
  #
  # All methods return the query builder for chaining.
  class WhereChain(Model)
    @query : Builder(Model)

    def initialize(@query : Builder(Model))
    end

    # NOT IN operator
    # ```
    # User.where.not_in(:id, [1, 2, 3])
    # # SQL: WHERE id NOT IN (1, 2, 3)
    # ```
    def not_in(field : Symbol | String, values : Array)
      @query.and_in(field, values, negated: true)
    end

    # LIKE operator for pattern matching
    # ```
    # User.where.like(:email, "%@gmail.com")
    # # SQL: WHERE email LIKE '%@gmail.com'
    # ```
    def like(field : Symbol | String, pattern : String)
      @query.and(field: field.to_s, operator: :like, value: pattern)
    end

    # NOT LIKE operator
    def not_like(field : Symbol | String, pattern : String)
      @query.and(field: field.to_s, operator: :nlike, value: pattern)
    end

    # Greater than comparison
    # ```
    # User.where.gt(:age, 18)
    # # SQL: WHERE age > 18
    # ```
    def gt(field : Symbol | String, value : Grant::Columns::Type)
      @query.and(field: field.to_s, operator: :gt, value: value)
    end

    # Less than
    def lt(field : Symbol | String, value : Grant::Columns::Type)
      @query.and(field: field.to_s, operator: :lt, value: value)
    end

    # Greater than or equal
    def gteq(field : Symbol | String, value : Grant::Columns::Type)
      @query.and(field: field.to_s, operator: :gteq, value: value)
    end

    # Less than or equal
    def lteq(field : Symbol | String, value : Grant::Columns::Type)
      @query.and(field: field.to_s, operator: :lteq, value: value)
    end

    # Not equal
    def not(field : Symbol | String, value : Grant::Columns::Type)
      @query.and(field: field.to_s, operator: :neq, value: value)
    end

    # NOT over several conditions: `where.not(a: 1, b: 2)` is
    # `NOT (a = 1 AND b = 2)`. Values follow `where`, so an array becomes
    # `NOT IN`, nil `IS NOT NULL` and a range a negated span.
    # ```
    # User.where.not(role: "admin", active: false)
    # # SQL: WHERE NOT (role = 'admin' AND active = false)
    # ```
    def not(**matches)
      @query.where_not(matches)
    end

    # IS NULL
    def is_null(field : Symbol | String)
      @query.and(field, :eq, nil)
    end

    # IS NOT NULL
    def is_not_null(field : Symbol | String)
      @query.and(field, :neq, nil)
    end

    # BETWEEN range check. An exclusive range excludes its upper endpoint.
    # ```
    # User.where.between(:age, 25..35)
    # # SQL: WHERE age >= 25 AND age <= 35
    # ```
    def between(field : Symbol | String, range : Range)
      @query
        .and(field: field.to_s, operator: :gteq, value: range.begin)
        .and(field: field.to_s, operator: range.exclusive? ? :lt : :lteq, value: range.end)
    end

    # EXISTS subquery condition
    # ```
    # User.where.exists(Post.where("posts.user_id = users.id"))
    # # SQL: WHERE EXISTS (SELECT * FROM posts WHERE posts.user_id = users.id)
    # ```
    def exists(subquery : Builder)
      subquery_assembler = subquery.assembler
      sql = subquery_assembler.select.raw_sql
      values = subquery_assembler.numbered_parameters
      if values.empty?
        @query.and("EXISTS (#{sql})")
      else
        @query.and(stmt: "EXISTS (#{sql})", values: values)
      end
    end

    # NOT EXISTS subquery
    def not_exists(subquery : Builder)
      subquery_assembler = subquery.assembler
      sql = subquery_assembler.select.raw_sql
      values = subquery_assembler.numbered_parameters
      if values.empty?
        @query.and("NOT EXISTS (#{sql})")
      else
        @query.and(stmt: "NOT EXISTS (#{sql})", values: values)
      end
    end

    # Checks if associated records exist using an INNER JOIN.
    #
    # Requires that the associated table and foreign key are provided
    # explicitly, as runtime association metadata lookup is not available
    # outside of macros in Crystal.
    #
    # ```
    # # Find users who have at least one post
    # User.where.has(:posts, table: "posts", foreign_key: "user_id")
    # # SQL: SELECT ... FROM users INNER JOIN posts ON posts.user_id = users.id
    # #      WHERE posts.user_id IS NOT NULL
    # ```
    def has(association : Symbol, *, table : String, foreign_key : String, primary_key : String = "id")
      @query
        .joins(table, on: "#{table}.#{foreign_key} = #{Model.table_name}.#{primary_key}")
        .and("#{table}.#{foreign_key} IS NOT NULL")
    end

    # Checks if associated records do NOT exist using a LEFT JOIN.
    #
    # Finds records that have no matching associated records.
    #
    # ```
    # # Find users who have no posts
    # User.where.missing(:posts, table: "posts", foreign_key: "user_id")
    # # SQL: SELECT ... FROM users LEFT JOIN posts ON posts.user_id = users.id
    # #      WHERE posts.user_id IS NULL
    # ```
    def missing(association : Symbol, *, table : String, foreign_key : String, primary_key : String = "id")
      @query
        .left_joins(table, on: "#{table}.#{foreign_key} = #{Model.table_name}.#{primary_key}")
        .and("#{table}.#{foreign_key} IS NULL")
    end

    # Keeps records that have a matching record in each named association,
    # using one `EXISTS` subquery per name (no duplicate parent rows).
    # ```
    # User.where.associated(:posts)
    # # SQL: WHERE EXISTS (SELECT 1 FROM posts AS assoc_target WHERE assoc_target.user_id = users.id)
    # ```
    def associated(*names : Symbol)
      @query.where_associated(names.to_a)
    end

    # Keeps records that have no matching record in any named association
    # (`NOT EXISTS`). `through`, `has_many ..., as:` and `belongs_to` work.
    # ```
    # User.where.missing(:posts)
    # ```
    def missing(*names : Symbol)
      @query.where_missing(names.to_a)
    end

    # Older name for `associated`, kept for compatibility.
    def has(*names : Symbol)
      associated(*names)
    end

    # PostgreSQL array columns contain every element of *values*.
    # ```
    # Post.where.array_contains(:tags, ["crystal"])
    # # SQL: WHERE tags @> $1   (one bound array)
    # ```
    def array_contains(field : Symbol | String, values : Grant::Columns::SupportedArrayTypes)
      @query.array_contains(field, values)
    end

    # PostgreSQL array column shares an element with *values* (`&&`).
    def array_overlaps(field : Symbol | String, values : Grant::Columns::SupportedArrayTypes)
      @query.array_overlaps(field, values)
    end

    # PostgreSQL array column holds *value* (`$1 = ANY(col)`).
    def any(field : Symbol | String, value : Grant::Columns::Type)
      @query.array_any(field, value)
    end

    # JSON column contains *document* (`@>` on PostgreSQL).
    # ```
    # User.where.json_contains(:settings, {theme: "dark"})
    # ```
    def json_contains(field : Symbol | String, document)
      @query.json_contains(field, document)
    end

    # JSON column holds *value* at *path* (`#>>` on PostgreSQL).
    # ```
    # User.where.json_path(:settings, "theme", "dark")
    # ```
    def json_path(field : Symbol | String, path : String | Array(String), value : String | Int | Float | Bool | Nil)
      @query.json_path(field, path, value)
    end

    # JSON object column has the top-level *key*.
    def json_has_key(field : Symbol | String, key : String)
      @query.json_has_key(field, key)
    end

    # Allow chaining back to the query builder
    macro method_missing(call)
      @query.{{call}}
    end
  end
end
