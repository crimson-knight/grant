require "../spec_helper"

# Test models
class Author < Granite::Base
  connection {{ CURRENT_ADAPTER }}
  table authors
  
  column id : Int64, primary: true
  column name : String
  
  has_many :posts
  has_one :profile
  
  # Enable nested attributes
  accepts_nested_attributes_for :posts, 
    allow_destroy: true,
    reject_if: :all_blank,
    limit: 5
    
  accepts_nested_attributes_for :profile,
    update_only: true
end

class Post < Granite::Base
  connection {{ CURRENT_ADAPTER }}
  table posts
  
  column id : Int64, primary: true
  column title : String
  column content : String?
  column author_id : Int64?
  
  belongs_to :author
  has_many :comments
  
  accepts_nested_attributes_for :comments,
    allow_destroy: true
end

class Comment < Granite::Base
  connection {{ CURRENT_ADAPTER }}
  table comments
  
  column id : Int64, primary: true
  column body : String
  column post_id : Int64?
  
  belongs_to :post
end

class Profile < Granite::Base
  connection {{ CURRENT_ADAPTER }}
  table profiles
  
  column id : Int64, primary: true
  column bio : String?
  column website : String?
  column author_id : Int64?
  
  belongs_to :author
end

# Setup tables
def setup_nested_attributes_tables
  case CURRENT_ADAPTER
  when "sqlite"
    Author.exec(<<-SQL)
      CREATE TABLE IF NOT EXISTS authors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created_at TEXT,
        updated_at TEXT
      )
    SQL
    
    Post.exec(<<-SQL)
      CREATE TABLE IF NOT EXISTS posts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        content TEXT,
        author_id INTEGER,
        created_at TEXT,
        updated_at TEXT,
        FOREIGN KEY(author_id) REFERENCES authors(id)
      )
    SQL
    
    Comment.exec(<<-SQL)
      CREATE TABLE IF NOT EXISTS comments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        body TEXT NOT NULL,
        post_id INTEGER,
        created_at TEXT,
        updated_at TEXT,
        FOREIGN KEY(post_id) REFERENCES comments(id)
      )
    SQL
    
    Profile.exec(<<-SQL)
      CREATE TABLE IF NOT EXISTS profiles (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bio TEXT,
        website TEXT,
        author_id INTEGER,
        created_at TEXT,
        updated_at TEXT,
        FOREIGN KEY(author_id) REFERENCES authors(id)
      )
    SQL
  when "pg"
    Author.exec(<<-SQL)
      CREATE TABLE IF NOT EXISTS authors (
        id BIGSERIAL PRIMARY KEY,
        name VARCHAR NOT NULL,
        created_at TIMESTAMP,
        updated_at TIMESTAMP
      )
    SQL
    
    Post.exec(<<-SQL)
      CREATE TABLE IF NOT EXISTS posts (
        id BIGSERIAL PRIMARY KEY,
        title VARCHAR NOT NULL,
        content TEXT,
        author_id BIGINT REFERENCES authors(id),
        created_at TIMESTAMP,
        updated_at TIMESTAMP
      )
    SQL
    
    Comment.exec(<<-SQL)
      CREATE TABLE IF NOT EXISTS comments (
        id BIGSERIAL PRIMARY KEY,
        body TEXT NOT NULL,
        post_id BIGINT REFERENCES posts(id),
        created_at TIMESTAMP,
        updated_at TIMESTAMP
      )
    SQL
    
    Profile.exec(<<-SQL)
      CREATE TABLE IF NOT EXISTS profiles (
        id BIGSERIAL PRIMARY KEY,
        bio TEXT,
        website VARCHAR,
        author_id BIGINT REFERENCES authors(id),
        created_at TIMESTAMP,
        updated_at TIMESTAMP
      )
    SQL
  when "mysql"
    Author.exec(<<-SQL)
      CREATE TABLE IF NOT EXISTS authors (
        id BIGINT PRIMARY KEY AUTO_INCREMENT,
        name VARCHAR(255) NOT NULL,
        created_at TIMESTAMP,
        updated_at TIMESTAMP
      )
    SQL
    
    Post.exec(<<-SQL)
      CREATE TABLE IF NOT EXISTS posts (
        id BIGINT PRIMARY KEY AUTO_INCREMENT,
        title VARCHAR(255) NOT NULL,
        content TEXT,
        author_id BIGINT,
        created_at TIMESTAMP,
        updated_at TIMESTAMP,
        FOREIGN KEY(author_id) REFERENCES authors(id)
      )
    SQL
    
    Comment.exec(<<-SQL)
      CREATE TABLE IF NOT EXISTS comments (
        id BIGINT PRIMARY KEY AUTO_INCREMENT,
        body TEXT NOT NULL,
        post_id BIGINT,
        created_at TIMESTAMP,
        updated_at TIMESTAMP,
        FOREIGN KEY(post_id) REFERENCES posts(id)
      )
    SQL
    
    Profile.exec(<<-SQL)
      CREATE TABLE IF NOT EXISTS profiles (
        id BIGINT PRIMARY KEY AUTO_INCREMENT,
        bio TEXT,
        website VARCHAR(255),
        author_id BIGINT,
        created_at TIMESTAMP,
        updated_at TIMESTAMP,
        FOREIGN KEY(author_id) REFERENCES authors(id)
      )
    SQL
  end
end

def cleanup_nested_attributes_tables
  Comment.exec("DROP TABLE IF EXISTS comments")
  Post.exec("DROP TABLE IF EXISTS posts")
  Profile.exec("DROP TABLE IF EXISTS profiles")
  Author.exec("DROP TABLE IF EXISTS authors")
end

describe Granite::NestedAttributes do
  before_each do
    cleanup_nested_attributes_tables
    setup_nested_attributes_tables
  end
  
  after_each do
    cleanup_nested_attributes_tables
  end
  
  describe "accepts_nested_attributes_for macro" do
    it "generates attribute setter methods" do
      author = Author.new(name: "John Doe")
      author.responds_to?(:posts_attributes=).should be_true
      author.responds_to?(:profile_attributes=).should be_true
    end
  end
  
  describe "creating nested records" do
    it "creates child records with has_many association" do
      author = Author.new(name: "John Doe")
      author.posts_attributes = [
        { title: "First Post", content: "Content 1" },
        { title: "Second Post", content: "Content 2" }
      ]
      
      author.save.should be_true
      author.id.should_not be_nil
      
      # Verify posts were created
      posts = Post.where(author_id: author.id).select
      posts.size.should eq(2)
      posts[0].title.should eq("First Post")
      posts[1].title.should eq("Second Post")
    end
    
    it "creates child record with has_one association" do
      author = Author.new(name: "Jane Doe")
      author.profile_attributes = {
        bio: "Software developer",
        website: "https://example.com"
      }
      
      author.save.should be_true
      
      # Verify profile was created
      profile = Profile.find_by(author_id: author.id)
      profile.should_not be_nil
      profile.not_nil!.bio.should eq("Software developer")
      profile.not_nil!.website.should eq("https://example.com")
    end
  end
  
  describe "updating nested records" do
    it "updates existing child records" do
      author = Author.create(name: "John Doe")
      post = Post.create(title: "Original Title", author_id: author.id)
      
      author.posts_attributes = [
        { id: post.id, title: "Updated Title" }
      ]
      
      author.save.should be_true
      
      # Verify post was updated
      updated_post = Post.find!(post.id)
      updated_post.title.should eq("Updated Title")
    end
  end
  
  describe "destroying nested records" do
    it "destroys child records when _destroy is true" do
      author = Author.create(name: "John Doe")
      post1 = Post.create(title: "Post 1", author_id: author.id)
      post2 = Post.create(title: "Post 2", author_id: author.id)
      
      author.posts_attributes = [
        { id: post1.id, _destroy: true },
        { id: post2.id, title: "Post 2 Updated" }
      ]
      
      author.save.should be_true
      
      # Verify post1 was destroyed and post2 was updated
      Post.find(post1.id).should be_nil
      Post.find!(post2.id).title.should eq("Post 2 Updated")
    end
    
    it "ignores _destroy when allow_destroy is false" do
      # Profile doesn't have allow_destroy
      author = Author.create(name: "Jane Doe")
      profile = Profile.create(bio: "Original bio", author_id: author.id)
      
      author.profile_attributes = {
        id: profile.id,
        _destroy: true,
        bio: "This should update"
      }
      
      author.save.should be_true
      
      # Profile should still exist and be updated
      updated_profile = Profile.find!(profile.id)
      updated_profile.bio.should eq("This should update")
    end
  end
  
  describe "reject_if option" do
    it "rejects all blank attributes" do
      author = Author.new(name: "John Doe")
      author.posts_attributes = [
        { title: "Valid Post", content: "Content" },
        { title: "", content: "" }, # Should be rejected
        { title: nil, content: nil } # Should be rejected
      ]
      
      author.save.should be_true
      
      # Only one post should be created
      posts = Post.where(author_id: author.id).select
      posts.size.should eq(1)
      posts[0].title.should eq("Valid Post")
    end
  end
  
  describe "limit option" do
    it "raises error when exceeding limit" do
      posts_attrs = (1..6).map { |i| { title: "Post #{i}" } }
      
      expect_raises(ArgumentError, /Maximum 5 records/) do
        author = Author.new(name: "John Doe")
        author.posts_attributes = posts_attrs
      end
    end
  end
  
  describe "update_only option" do
    it "does not create new records when update_only is true" do
      author = Author.create(name: "Jane Doe")
      
      # Try to create a profile (should be ignored)
      author.profile_attributes = {
        bio: "New bio",
        website: "https://example.com"
      }
      
      author.save.should be_true
      
      # No profile should be created
      Profile.find_by(author_id: author.id).should be_nil
    end
    
    it "updates existing records when update_only is true" do
      author = Author.create(name: "Jane Doe")
      profile = Profile.create(bio: "Original bio", author_id: author.id)
      
      author.profile_attributes = {
        id: profile.id,
        bio: "Updated bio"
      }
      
      author.save.should be_true
      
      # Profile should be updated
      updated_profile = Profile.find!(profile.id)
      updated_profile.bio.should eq("Updated bio")
    end
  end
  
  describe "validation propagation" do
    it "propagates validation errors from nested records" do
      author = Author.new(name: "John Doe")
      author.posts_attributes = [
        { title: "", content: "Content" } # Invalid - title required
      ]
      
      author.valid?.should be_false
      author.errors.size.should be > 0
      # Should have error related to nested post
      author.errors.any? { |e| e.field.to_s.includes?("post") || e.field.to_s.includes?("nested") }.should be_true
    end
  end
  
  describe "complex nested scenarios" do
    it "handles mixed create, update, and destroy operations" do
      author = Author.create(name: "John Doe")
      post1 = Post.create(title: "Post 1", author_id: author.id)
      post2 = Post.create(title: "Post 2", author_id: author.id)
      
      author.posts_attributes = [
        { id: post1.id, title: "Post 1 Updated" },      # Update
        { id: post2.id, _destroy: true },                # Destroy
        { title: "Post 3", content: "New content" }      # Create
      ]
      
      author.save.should be_true
      
      # Verify results
      posts = Post.where(author_id: author.id).select
      posts.size.should eq(2)
      
      # post1 should be updated
      Post.find!(post1.id).title.should eq("Post 1 Updated")
      
      # post2 should be destroyed
      Post.find(post2.id).should be_nil
      
      # New post should exist
      posts.any? { |p| p.title == "Post 3" }.should be_true
    end
  end
end