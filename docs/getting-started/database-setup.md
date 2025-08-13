---
title: "Database Setup Guide"
category: "core-features"
subcategory: "getting-started"
tags: ["database", "setup", "postgresql", "mysql", "sqlite", "configuration"]
complexity: "beginner"
version: "1.0.0"
prerequisites: ["installation.md"]
related_docs: ["first-model.md", "../advanced/data-management/migrations.md", "../infrastructure/multiple-databases/setup-configuration.md"]
last_updated: "2025-01-13"
estimated_read_time: "8 minutes"
use_cases: ["database-setup", "development-environment", "production-deployment"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Database Setup Guide

This guide covers detailed database setup for each supported database system, including development and production configurations.

## Supported Databases

| Database | Minimum Version | Recommended Version | Best For |
|----------|----------------|-------------------|----------|
| PostgreSQL | 9.5+ | 14+ | Production applications, complex queries, JSON support |
| MySQL | 5.6+ | 8.0+ | Web applications, WordPress-style apps |
| SQLite | 3.24.0+ | Latest | Development, testing, embedded applications |

## PostgreSQL Setup

### Installation

#### macOS
```bash
# Using Homebrew
brew install postgresql
brew services start postgresql

# Using MacPorts
sudo port install postgresql14-server
```

#### Ubuntu/Debian
```bash
sudo apt update
sudo apt install postgresql postgresql-contrib
sudo systemctl start postgresql
```

#### Docker
```bash
docker run --name grant-postgres \
  -e POSTGRES_PASSWORD=password \
  -e POSTGRES_DB=grant_db \
  -p 5432:5432 \
  -d postgres:14
```

### Database Configuration

```sql
-- Connect as superuser
sudo -u postgres psql

-- Create user with password
CREATE USER grant_user WITH PASSWORD 'secure_password';

-- Create development database
CREATE DATABASE grant_development OWNER grant_user;

-- Create test database
CREATE DATABASE grant_test OWNER grant_user;

-- Create production database
CREATE DATABASE grant_production OWNER grant_user;

-- Grant all privileges
GRANT ALL PRIVILEGES ON DATABASE grant_development TO grant_user;
GRANT ALL PRIVILEGES ON DATABASE grant_test TO grant_user;
GRANT ALL PRIVILEGES ON DATABASE grant_production TO grant_user;

-- Enable extensions (optional but recommended)
\c grant_development
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";      -- UUID support
CREATE EXTENSION IF NOT EXISTS "pgcrypto";       -- Encryption functions
CREATE EXTENSION IF NOT EXISTS "btree_gin";      -- Better indexing
CREATE EXTENSION IF NOT EXISTS "btree_gist";     -- Better indexing

-- Performance tuning for development
ALTER DATABASE grant_development SET shared_buffers = '256MB';
ALTER DATABASE grant_development SET work_mem = '4MB';
```

### Connection URLs

```crystal
# Development
Grant::Connections << Grant::Adapter::Pg.new(
  name: "development",
  url: "postgresql://grant_user:password@localhost:5432/grant_development"
)

# With SSL (production)
Grant::Connections << Grant::Adapter::Pg.new(
  name: "production",
  url: "postgresql://grant_user:password@host:5432/grant_production?sslmode=require"
)

# With connection pool settings
Grant::Connections << Grant::Adapter::Pg.new(
  name: "primary",
  url: ENV["DATABASE_URL"],
  pool_size: 25,
  initial_pool_size: 5,
  checkout_timeout: 5.seconds,
  retry_attempts: 3
)
```

### PostgreSQL-Specific Features

```crystal
# Using PostgreSQL arrays
class Product < Grant::Base
  column tags : Array(String)
  column prices : Array(Float64)
end

# Using JSONB
class Event < Grant::Base
  column metadata : JSON::Any
  column settings : JSON::Any
end

# Full-text search
Post.where("to_tsvector('english', content) @@ plainto_tsquery('english', ?)", ["crystal orm"])
```

## MySQL Setup

### Installation

#### macOS
```bash
# Using Homebrew
brew install mysql
brew services start mysql

# Secure installation
mysql_secure_installation
```

#### Ubuntu/Debian
```bash
sudo apt update
sudo apt install mysql-server
sudo systemctl start mysql
sudo mysql_secure_installation
```

#### Docker
```bash
docker run --name grant-mysql \
  -e MYSQL_ROOT_PASSWORD=rootpassword \
  -e MYSQL_DATABASE=grant_db \
  -e MYSQL_USER=grant_user \
  -e MYSQL_PASSWORD=password \
  -p 3306:3306 \
  -d mysql:8.0
```

### Database Configuration

```sql
-- Connect as root
mysql -u root -p

-- Create user (MySQL 8.0+)
CREATE USER 'grant_user'@'localhost' IDENTIFIED BY 'secure_password';
CREATE USER 'grant_user'@'%' IDENTIFIED BY 'secure_password';

-- For MySQL 5.7
CREATE USER 'grant_user'@'localhost' IDENTIFIED BY 'secure_password';

-- Create databases with proper encoding
CREATE DATABASE grant_development 
  CHARACTER SET utf8mb4 
  COLLATE utf8mb4_unicode_ci;

CREATE DATABASE grant_test 
  CHARACTER SET utf8mb4 
  COLLATE utf8mb4_unicode_ci;

CREATE DATABASE grant_production 
  CHARACTER SET utf8mb4 
  COLLATE utf8mb4_unicode_ci;

-- Grant privileges
GRANT ALL PRIVILEGES ON grant_development.* TO 'grant_user'@'localhost';
GRANT ALL PRIVILEGES ON grant_test.* TO 'grant_user'@'localhost';
GRANT ALL PRIVILEGES ON grant_production.* TO 'grant_user'@'%';

-- Apply changes
FLUSH PRIVILEGES;

-- Optimize for development
SET GLOBAL max_connections = 200;
SET GLOBAL innodb_buffer_pool_size = 268435456; -- 256MB
```

### Connection URLs

```crystal
# Basic connection
Grant::Connections << Grant::Adapter::Mysql.new(
  name: "mysql",
  url: "mysql://grant_user:password@localhost:3306/grant_development"
)

# With encoding specified
Grant::Connections << Grant::Adapter::Mysql.new(
  name: "mysql",
  url: "mysql://grant_user:password@localhost:3306/grant_development?encoding=utf8mb4"
)

# With SSL
Grant::Connections << Grant::Adapter::Mysql.new(
  name: "production",
  url: "mysql://grant_user:password@host:3306/grant_production?sslmode=REQUIRED"
)
```

### MySQL-Specific Features

```crystal
# Using MySQL enums (stored as strings in Grant)
class User < Grant::Base
  column status : String # ENUM('active', 'inactive', 'suspended')
  
  # Define enum helpers
  enum_field :status, ["active", "inactive", "suspended"]
end

# Full-text search with MySQL
Post.where("MATCH(title, content) AGAINST(? IN NATURAL LANGUAGE MODE)", ["crystal programming"])
```

## SQLite Setup

### Installation

#### macOS
```bash
# Usually pre-installed, but to get latest version:
brew install sqlite3
```

#### Ubuntu/Debian
```bash
sudo apt update
sudo apt install sqlite3 libsqlite3-dev
```

#### Verify Version
```bash
sqlite3 --version
# Must be 3.24.0 or higher
```

### Database Configuration

SQLite requires minimal setup:

```bash
# Create database directory
mkdir -p db

# Create database file (automatic on first connection)
touch db/development.db
touch db/test.db
touch db/production.db

# Set permissions
chmod 644 db/*.db
```

### Connection URLs

```crystal
# File-based database
Grant::Connections << Grant::Adapter::Sqlite.new(
  name: "sqlite",
  url: "sqlite3://./db/development.db"
)

# In-memory database (testing)
Grant::Connections << Grant::Adapter::Sqlite.new(
  name: "test",
  url: "sqlite3::memory:"
)

# With journal mode for better concurrency
Grant::Connections << Grant::Adapter::Sqlite.new(
  name: "sqlite",
  url: "sqlite3://./db/production.db?journal_mode=WAL"
)
```

### SQLite Configuration

```crystal
# Run after connecting
db = Grant::Connections["sqlite"]

# Enable foreign keys (disabled by default)
db.exec("PRAGMA foreign_keys = ON")

# Optimize for performance
db.exec("PRAGMA journal_mode = WAL")        # Write-Ahead Logging
db.exec("PRAGMA synchronous = NORMAL")      # Faster writes
db.exec("PRAGMA cache_size = -64000")       # 64MB cache
db.exec("PRAGMA temp_store = MEMORY")       # Use memory for temp tables
db.exec("PRAGMA mmap_size = 268435456")     # 256MB memory-mapped I/O
```

### SQLite-Specific Considerations

```crystal
# SQLite limitations to be aware of:
# 1. No ALTER COLUMN - must recreate table
# 2. Limited concurrent writes
# 3. No native BOOLEAN type (uses 0/1)

class Setting < Grant::Base
  # Boolean stored as INTEGER (0/1)
  column enabled : Bool
  
  # DateTime stored as TEXT
  column scheduled_at : Time
  
  # JSON stored as TEXT
  column preferences : JSON::Any
end
```

## Environment-Based Configuration

### Using .env Files

Create `.env` file:
```bash
# .env.development
DATABASE_URL=postgresql://grant_user:password@localhost:5432/grant_development
DATABASE_POOL_SIZE=5
DATABASE_TIMEOUT=5000

# .env.test
DATABASE_URL=sqlite3://./db/test.db
DATABASE_POOL_SIZE=1

# .env.production
DATABASE_URL=postgresql://user:pass@prod-host:5432/grant_production
DATABASE_POOL_SIZE=25
DATABASE_TIMEOUT=10000
```

Load configuration:
```crystal
# config/database.cr
require "dotenv"

# Load environment-specific config
env = ENV.fetch("CRYSTAL_ENV", "development")
Dotenv.load(".env.#{env}")

# Configure connection
Grant::Connections << Grant::Adapter.for(ENV["DATABASE_URL"]).new(
  name: "primary",
  url: ENV["DATABASE_URL"],
  pool_size: ENV.fetch("DATABASE_POOL_SIZE", "10").to_i,
  checkout_timeout: ENV.fetch("DATABASE_TIMEOUT", "5000").to_i.milliseconds
)
```

## Docker Compose Setup

Complete development environment:

```yaml
# docker-compose.yml
version: '3.8'

services:
  postgres:
    image: postgres:14
    environment:
      POSTGRES_USER: grant
      POSTGRES_PASSWORD: password
      POSTGRES_DB: grant_development
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U grant"]
      interval: 10s
      timeout: 5s
      retries: 5

  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: grant_development
      MYSQL_USER: grant
      MYSQL_PASSWORD: password
    volumes:
      - mysql_data:/var/lib/mysql
    ports:
      - "3306:3306"
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

  app:
    build: .
    depends_on:
      postgres:
        condition: service_healthy
      mysql:
        condition: service_healthy
    environment:
      PG_DATABASE_URL: postgresql://grant:password@postgres:5432/grant_development
      MYSQL_DATABASE_URL: mysql://grant:password@mysql:3306/grant_development
    volumes:
      - .:/app
      - ./db:/app/db
    command: crystal run src/app.cr

volumes:
  postgres_data:
  mysql_data:
```

## Testing Database Setup

Create a test script:

```crystal
# test_connection.cr
require "grant/adapter/pg"     # or mysql, sqlite

begin
  # Test connection
  Grant::Connections << Grant::Adapter::Pg.new(
    name: "test",
    url: ENV["DATABASE_URL"]
  )
  
  # Try a simple query
  db = Grant::Connections["test"]
  result = db.scalar("SELECT 1")
  
  puts "✅ Database connection successful!"
  puts "   Result: #{result}"
rescue ex
  puts "❌ Connection failed: #{ex.message}"
  puts "   Please check your database configuration"
  exit 1
end
```

Run test:
```bash
crystal run test_connection.cr
```

## Production Considerations

### Connection Pooling
```crystal
Grant::Connections << Grant::Adapter::Pg.new(
  name: "primary",
  url: ENV["DATABASE_URL"],
  pool_size: ENV.fetch("WEB_CONCURRENCY", "2").to_i * 25,
  initial_pool_size: 5,
  max_idle_pool_size: 10,
  checkout_timeout: 5.seconds,
  retry_attempts: 3,
  retry_delay: 0.2.seconds
)
```

### Read Replicas
```crystal
# Primary for writes
Grant::Connections << Grant::Adapter::Pg.new(
  name: "primary",
  url: ENV["PRIMARY_DATABASE_URL"]
)

# Replica for reads
Grant::Connections << Grant::Adapter::Pg.new(
  name: "replica",
  url: ENV["REPLICA_DATABASE_URL"]
)
```

### SSL/TLS Configuration
```crystal
# PostgreSQL with SSL
url = "postgresql://user:pass@host/db?sslmode=require&sslcert=/path/to/cert"

# MySQL with SSL
url = "mysql://user:pass@host/db?sslmode=REQUIRED&sslca=/path/to/ca.pem"
```

## Troubleshooting

### Common Issues

1. **Version too old**
   - Update your database server
   - Use Docker for consistent versions

2. **Connection refused**
   ```bash
   # Check if service is running
   systemctl status postgresql  # or mysql
   ps aux | grep postgres       # or mysqld
   ```

3. **Authentication failed**
   ```bash
   # PostgreSQL: Check pg_hba.conf
   sudo nano /etc/postgresql/14/main/pg_hba.conf
   
   # MySQL: Check user privileges
   SELECT user, host FROM mysql.user;
   ```

4. **Database doesn't exist**
   ```sql
   -- List databases
   \l  -- PostgreSQL
   SHOW DATABASES;  -- MySQL
   ```

## Next Steps

- [Create your first model](first-model.md)
- [Learn about migrations](../advanced/data-management/migrations.md)
- [Set up multiple databases](../infrastructure/multiple-databases/setup-configuration.md)
- [Configure for production](../development/deployment-guide.md)