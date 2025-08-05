require "../src/granite"

# Advanced Query Interface Examples

class User < Granite::Base
  connection "primary"
  table users
  
  column id : Int64, primary: true
  column name : String
  column email : String
  column role : String
  column active : Bool = true
  column age : Int32?
  column deleted_at : Time?
  column confirmed_at : Time?
  column created_at : Time = Time.utc
  
  has_many posts : Post
  has_many comments : Comment
end

class Post < Granite::Base
  connection "primary"  
  table posts
  
  column id : Int64, primary: true
  column user_id : Int64
  column title : String
  column content : String
  column published : Bool = false
  column views : Int32 = 0
  column created_at : Time = Time.utc
  
  belongs_to user : User
  has_many comments : Comment
end

class Comment < Granite::Base
  connection "primary"
  table comments
  
  column id : Int64, primary: true
  column user_id : Int64
  column post_id : Int64
  column content : String
  column spam : Bool = false
  column created_at : Time = Time.utc
  
  belongs_to user : User
  belongs_to post : Post
end

# 1. Query Merging
# Combine multiple query conditions
active_users = User.where(active: true)
admin_users = User.where(role: "admin")
active_admins = active_users.merge(admin_users)
# SQL: WHERE active = true AND role = 'admin'

# Merge with different conditions
recent_users = User.where("created_at > ?", 30.days.ago).order(created_at: :desc)
merged = active_admins.merge(recent_users)
# Inherits all conditions and uses recent_users' ordering

# 2. Advanced Where Chain Methods
# NOT IN
users_to_exclude = [1, 2, 3, 4, 5]
User.where.not_in(:id, users_to_exclude)

# LIKE patterns
User.where.like(:email, "%@gmail.com")
User.where.not_like(:email, "%spam%")

# Comparison operators
User.where.gt(:age, 18).lt(:age, 65)
User.where.gteq(:created_at, 1.week.ago)

# NULL checks
User.where.is_null(:deleted_at)      # Not soft-deleted
User.where.is_not_null(:confirmed_at) # Email confirmed

# BETWEEN
User.where.between(:age, 25..35)

# Chaining multiple conditions
User.where(active: true)
    .where.not_like(:email, "%test%")
    .where.is_not_null(:confirmed_at)
    .where.between(:age, 18..65)

# 3. Subqueries
# IN subquery - find posts by admin users
admin_ids = User.where(role: "admin").select(:id)
admin_posts = Post.where(user_id: admin_ids)

# EXISTS subquery - find users who have posts
users_with_posts = User.where.exists(
  Post.where("posts.user_id = users.id")
)

# NOT EXISTS - find users without any posts
users_without_posts = User.where.not_exists(
  Post.where("posts.user_id = users.id")
)

# Complex subquery - users who have commented on their own posts
users_self_commented = User.where.exists(
  Comment.where("comments.user_id = users.id")
         .where("comments.post_id IN (SELECT id FROM posts WHERE posts.user_id = users.id)")
)

# 4. Complex Query Combinations
# Find active adult users who are confirmed, have posts, but aren't admins
complex_query = User
  .where(active: true)
  .where.gteq(:age, 18)
  .where.is_not_null(:confirmed_at)
  .where.not(:role, "admin")
  .where.exists(Post.where("posts.user_id = users.id"))
  .order(created_at: :desc)
  .limit(20)

# Combining OR and NOT conditions
# Find users who are either admins OR (active AND confirmed)
User.where(role: "admin")
    .or do |q|
      q.where(active: true)
      q.where.is_not_null(:confirmed_at) 
    end

# Complex NOT conditions
# Find users who are NOT (inactive AND unconfirmed)
User.not do |q|
  q.where(active: false)
  q.where.is_null(:confirmed_at)
end

# 5. Query Composition
# Build queries incrementally
def build_user_query(filters = {} of String => String)
  query = User.where(active: true)
  
  if role = filters["role"]?
    query = query.where(role: role)
  end
  
  if min_age = filters["min_age"]?
    query = query.where.gteq(:age, min_age.to_i)
  end
  
  if email_pattern = filters["email_like"]?
    query = query.where.like(:email, email_pattern)
  end
  
  if has_posts = filters["has_posts"]?
    query = query.where.exists(Post.where("posts.user_id = users.id"))
  end
  
  query.order(created_at: :desc)
end

# Use the composed query
filters = {
  "role" => "member",
  "min_age" => "25", 
  "email_like" => "%@company.com",
  "has_posts" => "true"
}
results = build_user_query(filters).select

# 6. Copying and Modifying Queries
base_query = User.where(active: true).order(name: :asc)

# Create variations without modifying the original
with_admins = base_query.dup.where(role: "admin")
with_members = base_query.dup.where(role: "member")
recent_only = base_query.dup.where.gteq(:created_at, 7.days.ago)

# 7. Performance Optimization with Select
# Only fetch IDs for subqueries
active_user_ids = User.where(active: true).select(:id)
Post.where(user_id: active_user_ids).where(published: true)

# 8. Real-world Example: Admin Dashboard Query
# Find problematic content: unpublished posts with spam comments
problematic_posts = Post
  .where(published: false)
  .where.exists(
    Comment.where("comments.post_id = posts.id")
           .where(spam: true)
  )
  .where.not_in(:user_id, User.where(role: "admin").select(:id))
  .order(created_at: :desc)
  .limit(50)

puts "Advanced query examples demonstrate the power of Grant's query interface"