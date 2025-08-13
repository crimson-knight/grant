---
title: "Database Migrations"
category: "advanced"
subcategory: "data-management"
tags: ["migrations", "schema", "database", "ddl", "versioning", "rollback", "micrate"]
complexity: "intermediate"
version: "1.0.0"
prerequisites: ["../../getting-started/database-setup.md", "../../core-features/models-and-columns.md"]
related_docs: ["../../getting-started/database-setup.md", "normalization.md", "../infrastructure/multiple-databases.md"]
last_updated: "2025-01-13"
estimated_read_time: "20 minutes"
use_cases: ["schema-management", "database-versioning", "deployment", "team-collaboration"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Database Migrations

Comprehensive guide to managing database schema changes using migrations with Grant and Micrate, including best practices, advanced patterns, and team collaboration strategies.

## Overview

Database migrations provide version control for your database schema, allowing you to:
- Track schema changes over time
- Collaborate with team members
- Deploy changes safely
- Rollback problematic changes
- Keep multiple environments in sync

Grant integrates with [Micrate](https://github.com/juanedi/micrate) for migration management, providing a robust solution for schema versioning.

## Setup and Configuration

### Installing Micrate

Add Micrate to your `shard.yml`:

```yaml
dependencies:
  micrate:
    github: juanedi/micrate
  
  # Database drivers
  pg:
    github: will/crystal-pg  # PostgreSQL
  mysql:
    github: crystal-lang/crystal-mysql  # MySQL
  sqlite3:
    github: crystal-lang/crystal-sqlite3  # SQLite
```

### Creating Migration Runner

Create `bin/micrate`:

```crystal
#!/usr/bin/env crystal

require "micrate"
require "pg"  # or mysql, sqlite3

# Configuration from environment
Micrate::DB.connection_url = ENV["DATABASE_URL"]

# Optional: Configure migration directory
Micrate.migrations_dir = "db/migrations"

# Optional: Configure schema table name
Micrate.migrations_table = "schema_migrations"

# Run CLI
Micrate::Cli.run
```

Make it executable:

```bash
chmod +x bin/micrate
```

### Advanced Configuration

```crystal
#!/usr/bin/env crystal

require "micrate"
require "./config/database"

# Multiple database support
case ENV["MIGRATE_DB"]?
when "primary"
  Micrate::DB.connection_url = ENV["PRIMARY_DATABASE_URL"]
when "analytics"
  Micrate::DB.connection_url = ENV["ANALYTICS_DATABASE_URL"]
else
  Micrate::DB.connection_url = ENV["DATABASE_URL"]
end

# Custom configuration
Micrate.configure do |config|
  config.migrations_dir = ENV["MIGRATIONS_DIR"]? || "db/migrations"
  config.migrations_table = ENV["MIGRATIONS_TABLE"]? || "schema_migrations"
  config.verbose = ENV["VERBOSE"]? == "true"
end

Micrate::Cli.run
```

## Creating Migrations

### Basic Migration Structure

```bash
# Generate migration scaffold
bin/micrate scaffold create_users
```

This creates `db/migrations/[timestamp]_create_users.sql`:

```sql
-- +micrate Up
-- SQL in section 'Up' is executed when this migration is applied

-- +micrate Down
-- SQL section 'Down' is executed when this migration is rolled back
```

### Table Creation

```sql
-- +micrate Up
CREATE TABLE users (
  id BIGSERIAL PRIMARY KEY,
  email VARCHAR(255) NOT NULL UNIQUE,
  encrypted_password VARCHAR(255) NOT NULL,
  first_name VARCHAR(100),
  last_name VARCHAR(100),
  active BOOLEAN DEFAULT true,
  role VARCHAR(50) DEFAULT 'user',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_active ON users(active) WHERE active = true;
CREATE INDEX idx_users_created_at ON users(created_at DESC);

-- +micrate Down
DROP TABLE IF EXISTS users CASCADE;
```

### Complex Table with Constraints

```sql
-- +micrate Up
-- Create enum type (PostgreSQL)
CREATE TYPE order_status AS ENUM ('pending', 'processing', 'shipped', 'delivered', 'cancelled');

CREATE TABLE orders (
  id BIGSERIAL PRIMARY KEY,
  order_number VARCHAR(20) NOT NULL UNIQUE,
  user_id BIGINT NOT NULL,
  status order_status DEFAULT 'pending',
  total DECIMAL(10, 2) NOT NULL CHECK (total >= 0),
  currency VARCHAR(3) DEFAULT 'USD',
  shipping_address JSONB,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  
  -- Foreign key constraint
  CONSTRAINT fk_orders_user 
    FOREIGN KEY (user_id) 
    REFERENCES users(id) 
    ON DELETE RESTRICT
);

-- Indexes
CREATE INDEX idx_orders_user_id ON orders(user_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_orders_created_at ON orders(created_at DESC);
CREATE INDEX idx_orders_metadata ON orders USING gin(metadata);  -- JSONB index

-- +micrate Down
DROP TABLE IF EXISTS orders CASCADE;
DROP TYPE IF EXISTS order_status;
```

## Migration Patterns

### Adding Columns

```sql
-- +micrate Up
-- Add column with default value
ALTER TABLE users 
ADD COLUMN phone VARCHAR(20),
ADD COLUMN email_verified BOOLEAN DEFAULT false,
ADD COLUMN email_verified_at TIMESTAMP;

-- Backfill existing data
UPDATE users SET email_verified = true WHERE created_at < '2024-01-01';

-- Add constraint after backfill
ALTER TABLE users 
ADD CONSTRAINT check_email_verification 
CHECK (email_verified = false OR email_verified_at IS NOT NULL);

-- +micrate Down
ALTER TABLE users 
DROP CONSTRAINT IF EXISTS check_email_verification,
DROP COLUMN IF EXISTS phone,
DROP COLUMN IF EXISTS email_verified,
DROP COLUMN IF EXISTS email_verified_at;
```

### Renaming Columns

```sql
-- +micrate Up
-- PostgreSQL/SQLite
ALTER TABLE users RENAME COLUMN username TO handle;

-- MySQL (prior to 8.0)
ALTER TABLE users CHANGE username handle VARCHAR(50);

-- Update dependent views/functions if needed
-- ...

-- +micrate Down
ALTER TABLE users RENAME COLUMN handle TO username;
```

### Changing Column Types

```sql
-- +micrate Up
-- Safe type change with explicit casting
ALTER TABLE products 
ALTER COLUMN price TYPE DECIMAL(10, 2) USING price::decimal(10, 2);

-- Change with data transformation
ALTER TABLE users 
ALTER COLUMN status TYPE VARCHAR(20) 
USING CASE 
  WHEN status = 1 THEN 'active'
  WHEN status = 0 THEN 'inactive'
  ELSE 'unknown'
END;

-- +micrate Down
-- Reverse the changes
ALTER TABLE products 
ALTER COLUMN price TYPE INTEGER USING (price * 100)::integer;

ALTER TABLE users 
ALTER COLUMN status TYPE INTEGER 
USING CASE 
  WHEN status = 'active' THEN 1
  WHEN status = 'inactive' THEN 0
  ELSE NULL
END;
```

### Creating Indexes

```sql
-- +micrate Up
-- Simple index
CREATE INDEX idx_posts_user_id ON posts(user_id);

-- Composite index
CREATE INDEX idx_posts_user_published ON posts(user_id, published, created_at DESC);

-- Partial index
CREATE INDEX idx_posts_published ON posts(created_at DESC) 
WHERE published = true;

-- Unique index
CREATE UNIQUE INDEX idx_users_email_lower ON users(lower(email));

-- Concurrent index creation (PostgreSQL - non-blocking)
CREATE INDEX CONCURRENTLY idx_orders_total ON orders(total);

-- Full-text search index (PostgreSQL)
CREATE INDEX idx_posts_search ON posts 
USING gin(to_tsvector('english', title || ' ' || body));

-- +micrate Down
DROP INDEX IF EXISTS idx_posts_user_id;
DROP INDEX IF EXISTS idx_posts_user_published;
DROP INDEX IF EXISTS idx_posts_published;
DROP INDEX IF EXISTS idx_users_email_lower;
DROP INDEX IF EXISTS idx_orders_total;
DROP INDEX IF EXISTS idx_posts_search;
```

### Foreign Keys and Constraints

```sql
-- +micrate Up
-- Add foreign key to existing table
ALTER TABLE posts 
ADD COLUMN category_id BIGINT,
ADD CONSTRAINT fk_posts_category 
  FOREIGN KEY (category_id) 
  REFERENCES categories(id) 
  ON DELETE SET NULL;

-- Add check constraint
ALTER TABLE users 
ADD CONSTRAINT check_age 
CHECK (age >= 18 AND age <= 120);

-- Add unique constraint
ALTER TABLE products 
ADD CONSTRAINT unique_sku 
UNIQUE (sku);

-- Composite unique constraint
ALTER TABLE user_roles 
ADD CONSTRAINT unique_user_role 
UNIQUE (user_id, role_id);

-- +micrate Down
ALTER TABLE posts DROP CONSTRAINT IF EXISTS fk_posts_category;
ALTER TABLE posts DROP COLUMN IF EXISTS category_id;
ALTER TABLE users DROP CONSTRAINT IF EXISTS check_age;
ALTER TABLE products DROP CONSTRAINT IF EXISTS unique_sku;
ALTER TABLE user_roles DROP CONSTRAINT IF EXISTS unique_user_role;
```

## Advanced Migrations

### Data Migrations

```sql
-- +micrate Up
-- Step 1: Add new column
ALTER TABLE users ADD COLUMN full_name VARCHAR(200);

-- Step 2: Migrate data
UPDATE users 
SET full_name = CONCAT(first_name, ' ', last_name)
WHERE first_name IS NOT NULL OR last_name IS NOT NULL;

-- Step 3: Add NOT NULL constraint after data migration
ALTER TABLE users ALTER COLUMN full_name SET NOT NULL;

-- Step 4: Drop old columns (consider doing this in a separate migration)
-- ALTER TABLE users DROP COLUMN first_name, DROP COLUMN last_name;

-- +micrate Down
-- Reverse the migration
ALTER TABLE users ADD COLUMN first_name VARCHAR(100);
ALTER TABLE users ADD COLUMN last_name VARCHAR(100);

UPDATE users 
SET 
  first_name = SPLIT_PART(full_name, ' ', 1),
  last_name = SPLIT_PART(full_name, ' ', 2)
WHERE full_name IS NOT NULL;

ALTER TABLE users DROP COLUMN full_name;
```

### Creating Views

```sql
-- +micrate Up
CREATE OR REPLACE VIEW active_users AS
SELECT 
  u.id,
  u.email,
  u.full_name,
  COUNT(DISTINCT p.id) as post_count,
  COUNT(DISTINCT c.id) as comment_count,
  MAX(p.created_at) as last_post_at
FROM users u
LEFT JOIN posts p ON p.user_id = u.id AND p.published = true
LEFT JOIN comments c ON c.user_id = u.id
WHERE u.active = true
GROUP BY u.id, u.email, u.full_name;

-- Materialized view for performance (PostgreSQL)
CREATE MATERIALIZED VIEW user_statistics AS
SELECT 
  user_id,
  COUNT(*) as total_posts,
  SUM(view_count) as total_views,
  AVG(view_count) as avg_views
FROM posts
WHERE published = true
GROUP BY user_id;

CREATE INDEX idx_user_statistics_user_id ON user_statistics(user_id);

-- +micrate Down
DROP MATERIALIZED VIEW IF EXISTS user_statistics;
DROP VIEW IF EXISTS active_users;
```

### Stored Procedures and Functions

```sql
-- +micrate Up
-- PostgreSQL function
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply trigger to tables
CREATE TRIGGER update_users_updated_at 
  BEFORE UPDATE ON users 
  FOR EACH ROW 
  EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER update_posts_updated_at 
  BEFORE UPDATE ON posts 
  FOR EACH ROW 
  EXECUTE FUNCTION update_updated_at();

-- +micrate Down
DROP TRIGGER IF EXISTS update_users_updated_at ON users;
DROP TRIGGER IF EXISTS update_posts_updated_at ON posts;
DROP FUNCTION IF EXISTS update_updated_at();
```

### Partitioning Tables

```sql
-- +micrate Up
-- Create partitioned table (PostgreSQL)
CREATE TABLE events (
  id BIGSERIAL,
  event_type VARCHAR(50) NOT NULL,
  user_id BIGINT,
  data JSONB,
  created_at TIMESTAMP NOT NULL
) PARTITION BY RANGE (created_at);

-- Create partitions
CREATE TABLE events_2024_01 PARTITION OF events
  FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE events_2024_02 PARTITION OF events
  FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

-- Create indexes on partitions
CREATE INDEX idx_events_2024_01_user_id ON events_2024_01(user_id);
CREATE INDEX idx_events_2024_02_user_id ON events_2024_02(user_id);

-- +micrate Down
DROP TABLE IF EXISTS events CASCADE;
```

## Migration Best Practices

### 1. Atomic Migrations

```sql
-- Good: Single responsibility
-- Migration: add_email_verification_to_users.sql
ALTER TABLE users ADD COLUMN email_verified BOOLEAN DEFAULT false;

-- Bad: Multiple unrelated changes
-- Don't mix unrelated schema changes
ALTER TABLE users ADD COLUMN email_verified BOOLEAN;
ALTER TABLE posts ADD COLUMN view_count INTEGER;
CREATE TABLE categories (...);
```

### 2. Reversible Migrations

```sql
-- Always provide rollback logic
-- +micrate Up
ALTER TABLE users ADD COLUMN phone VARCHAR(20);

-- +micrate Down
ALTER TABLE users DROP COLUMN phone;  -- Data will be lost!

-- Better: Consider data preservation
-- +micrate Down
-- Warning: This will drop the phone column and its data
-- Consider backing up: SELECT id, phone FROM users WHERE phone IS NOT NULL;
ALTER TABLE users DROP COLUMN phone;
```

### 3. Safe Migrations

```crystal
# Create a migration helper for safety checks
class MigrationSafety
  def self.check_migration(sql : String)
    dangerous_patterns = [
      /DROP\s+TABLE/i,
      /DROP\s+COLUMN/i,
      /ALTER\s+COLUMN.*TYPE/i,
      /RENAME\s+COLUMN/i
    ]
    
    warnings = [] of String
    
    dangerous_patterns.each do |pattern|
      if sql.matches?(pattern)
        warnings << "Potentially dangerous operation: #{pattern}"
      end
    end
    
    if warnings.any?
      puts "⚠️  Migration warnings:"
      warnings.each { |w| puts "  - #{w}" }
      print "Continue? (y/n): "
      response = gets
      exit unless response == "y"
    end
  end
end
```

### 4. Performance Considerations

```sql
-- Use CONCURRENTLY for large tables (PostgreSQL)
-- +micrate Up
-- This won't lock the table but takes longer
CREATE INDEX CONCURRENTLY idx_large_table_column ON large_table(column);

-- For large data updates, batch them
DO $$
DECLARE
  batch_size INTEGER := 1000;
  offset_val INTEGER := 0;
BEGIN
  LOOP
    UPDATE users 
    SET normalized_email = LOWER(email)
    WHERE id IN (
      SELECT id FROM users 
      WHERE normalized_email IS NULL 
      LIMIT batch_size 
      OFFSET offset_val
    );
    
    EXIT WHEN NOT FOUND;
    offset_val := offset_val + batch_size;
    
    -- Optional: Add delay to reduce load
    PERFORM pg_sleep(0.1);
  END LOOP;
END $$;
```

## Team Collaboration

### Migration Naming Conventions

```bash
# Timestamp prefix prevents conflicts
20240201123456_create_users.sql
20240201123457_add_email_verification_to_users.sql
20240201123458_create_posts.sql
20240201123459_add_foreign_keys.sql

# Descriptive names
good: add_email_verification_to_users.sql
bad: update_users.sql
bad: migration_1.sql
```

### Migration Review Checklist

```markdown
## Migration Review Checklist

- [ ] Migration is reversible (has DOWN section)
- [ ] Tested on development database
- [ ] Performance impact assessed for large tables
- [ ] Foreign keys have appropriate ON DELETE behavior
- [ ] Indexes added for foreign keys
- [ ] Data migration handles NULL values
- [ ] Check constraints are valid for existing data
- [ ] Migration doesn't break existing code
- [ ] Documentation updated if needed
```

### Handling Migration Conflicts

```bash
# When multiple developers create migrations
# Developer A: 20240201120000_add_phone_to_users.sql
# Developer B: 20240201120000_add_address_to_users.sql

# Resolution:
# 1. Rename one migration with later timestamp
mv 20240201120000_add_address_to_users.sql 20240201120001_add_address_to_users.sql

# 2. Update schema_migrations if needed
DELETE FROM schema_migrations WHERE version = '20240201120000_add_address_to_users';
INSERT INTO schema_migrations (version) VALUES ('20240201120001');
```

## Testing Migrations

### Migration Testing Strategy

```crystal
# spec/migrations/migration_spec.cr
describe "Migrations" do
  before_each do
    # Create test database
    `createdb grant_test_migrations`
    ENV["DATABASE_URL"] = "postgresql://localhost/grant_test_migrations"
  end
  
  after_each do
    # Clean up
    `dropdb grant_test_migrations`
  end
  
  it "applies all migrations successfully" do
    result = `bin/micrate up`
    result.should contain("Migration successful")
  end
  
  it "rolls back migrations successfully" do
    `bin/micrate up`
    result = `bin/micrate down`
    result.should contain("Rollback successful")
  end
  
  it "maintains data integrity during migration" do
    # Setup test data
    Grant.connection.exec("INSERT INTO users ...")
    
    # Run migration
    `bin/micrate up`
    
    # Verify data
    count = Grant.connection.query_one("SELECT COUNT(*) FROM users", as: Int64)
    count.should eq(expected_count)
  end
end
```

### Continuous Integration

```yaml
# .github/workflows/migrations.yml
name: Test Migrations

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    
    services:
      postgres:
        image: postgres:14
        env:
          POSTGRES_PASSWORD: postgres
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    
    steps:
    - uses: actions/checkout@v2
    
    - name: Install Crystal
      uses: crystal-lang/install-crystal@v1
      
    - name: Install dependencies
      run: shards install
      
    - name: Run migrations up
      run: bin/micrate up
      env:
        DATABASE_URL: postgresql://postgres:postgres@localhost/test
        
    - name: Run migrations down
      run: bin/micrate down
      env:
        DATABASE_URL: postgresql://postgres:postgres@localhost/test
```

## Production Deployment

### Zero-Downtime Migrations

```crystal
# Strategy for adding NOT NULL column
class AddRequiredColumn
  def self.execute
    # Step 1: Add nullable column
    run_migration("add_column_nullable")
    
    # Step 2: Deploy code that writes to new column
    deploy_application("v2.0.0")
    
    # Step 3: Backfill existing data
    run_migration("backfill_data")
    
    # Step 4: Add NOT NULL constraint
    run_migration("add_not_null_constraint")
    
    # Step 5: Deploy code that requires new column
    deploy_application("v2.1.0")
  end
end
```

### Migration Monitoring

```crystal
class MigrationMonitor
  def self.track(migration_name : String)
    start_time = Time.utc
    
    Log.info { "Starting migration: #{migration_name}" }
    
    begin
      yield
      
      duration = Time.utc - start_time
      Log.info { "Migration completed: #{migration_name} (#{duration.total_seconds}s)" }
      
      # Alert if migration took too long
      if duration > 5.minutes
        AlertService.notify("Slow migration: #{migration_name}")
      end
    rescue ex
      Log.error { "Migration failed: #{migration_name} - #{ex.message}" }
      AlertService.critical("Migration failed: #{migration_name}")
      raise ex
    end
  end
end
```

## Troubleshooting

### Common Issues

**Migration locked:**
```sql
-- Check for locks (PostgreSQL)
SELECT * FROM pg_locks WHERE NOT granted;

-- Kill blocking session
SELECT pg_terminate_backend(pid) 
FROM pg_stat_activity 
WHERE state = 'idle in transaction' 
  AND query_start < NOW() - INTERVAL '10 minutes';
```

**Schema out of sync:**
```bash
# Check current version
bin/micrate version

# Force version (use carefully)
psql -c "INSERT INTO schema_migrations (version) VALUES ('20240201120000')"

# Rerun from specific version
bin/micrate down --to 20240201000000
bin/micrate up
```

**Performance issues:**
```sql
-- Check migration progress
SELECT * FROM pg_stat_progress_create_index;  -- PostgreSQL

-- Monitor long-running migrations
SELECT pid, now() - query_start as duration, query 
FROM pg_stat_activity 
WHERE query LIKE '%ALTER TABLE%' 
ORDER BY duration DESC;
```

## Next Steps

- [Dirty Tracking](dirty-tracking.md)
- [Import/Export](imports-exports.md)
- [Normalization](normalization.md)
- [Backup Strategies](backup-strategies.md)