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
      @query.and(field: field.to_s, operator: :nin, value: values)
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
    
    # IS NULL
    def is_null(field : Symbol | String)
      @query.and(stmt: "#{field} IS NULL", value: nil)
    end
    
    # IS NOT NULL
    def is_not_null(field : Symbol | String)
      @query.and(stmt: "#{field} IS NOT NULL", value: nil)
    end
    
    # BETWEEN range check (inclusive)
    # ```
    # User.where.between(:age, 25..35)
    # # SQL: WHERE age >= 25 AND age <= 35
    # ```
    def between(field : Symbol | String, range : Range)
      @query.and(field: field.to_s, operator: :gteq, value: range.begin)
      @query.and(field: field.to_s, operator: :lteq, value: range.end)
    end
    
    # EXISTS subquery condition
    # ```
    # User.where.exists(Post.where("posts.user_id = users.id"))
    # # SQL: WHERE EXISTS (SELECT * FROM posts WHERE posts.user_id = users.id)
    # ```
    def exists(subquery : Builder)
      sql = subquery.assembler.select.raw_sql
      @query.and(stmt: "EXISTS (#{sql})", value: nil)
    end
    
    # NOT EXISTS subquery
    def not_exists(subquery : Builder)
      sql = subquery.assembler.select.raw_sql
      @query.and(stmt: "NOT EXISTS (#{sql})", value: nil)
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
      @query.joins(table, on: "#{table}.#{foreign_key} = #{Model.table_name}.#{primary_key}")
      @query.and(stmt: "#{table}.#{foreign_key} IS NOT NULL", value: nil)
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
      @query.left_joins(table, on: "#{table}.#{foreign_key} = #{Model.table_name}.#{primary_key}")
      @query.and(stmt: "#{table}.#{foreign_key} IS NULL", value: nil)
    end
    
    # Allow chaining back to the query builder
    macro method_missing(call)
      @query.{{call}}
    end
  end
end