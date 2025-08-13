---
title: "Installation and Setup"
category: "core-features"
subcategory: "getting-started"
tags: ["installation", "setup", "configuration", "database", "orm"]
complexity: "beginner"
version: "1.0.0"
prerequisites: []
related_docs: ["database-setup.md", "first-model.md", "quick-start.md"]
last_updated: "2025-01-13"
estimated_read_time: "5 minutes"
use_cases: ["web-development", "api-building", "database-applications"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Installation and Setup

Grant is a powerful ORM (Object-Relational Mapping) library for Crystal, originally designed for the [Amber](https://github.com/amberframework/amber) framework but compatible with any Crystal web framework including Kemal.

## Prerequisites

- Crystal language installed (latest stable version recommended)
- Access to one of the supported databases:
  - PostgreSQL 9.5+ (for ON CONFLICT support)
  - MySQL 5.6+ (for ON DUPLICATE KEY UPDATE)
  - SQLite 3.24.0+ (for ON CONFLICT support, enforced at runtime)

## Installation

Add Grant and your chosen database driver to your project's `shard.yml`:

```yaml
dependencies:
  grant:
    github: amberframework/grant

  # Choose one or more database drivers:
  
  # PostgreSQL
  pg:
    github: will/crystal-pg

  # MySQL  
  mysql:
    github: crystal-lang/crystal-mysql

  # SQLite
  sqlite3:
    github: crystal-lang/crystal-sqlite3
```

Then install the dependencies:

```bash
shards install
```

## Basic Configuration

### 1. Register a Database Connection

Register your database connection early in your application, before requiring Grant models:

```crystal
# For PostgreSQL
Grant::Connections << Grant::Adapter::Pg.new(
  name: "pg", 
  url: "postgresql://user:password@localhost/database_name"
)

# For MySQL
Grant::Connections << Grant::Adapter::Mysql.new(
  name: "mysql",
  url: "mysql://user:password@localhost/database_name"
)

# For SQLite
Grant::Connections << Grant::Adapter::Sqlite.new(
  name: "sqlite",
  url: "sqlite3://./database.db"
)
```

### 2. Environment-Based Configuration

For production applications, use environment variables:

```crystal
# config/database.cr
database_url = ENV["DATABASE_URL"]

Grant::Connections << Grant::Adapter::Pg.new(
  name: "primary",
  url: database_url
)
```

### 3. Multiple Database Support

Grant supports multiple database connections:

```crystal
# Primary database
Grant::Connections << Grant::Adapter::Pg.new(
  name: "primary",
  url: ENV["PRIMARY_DATABASE_URL"]
)

# Read replica
Grant::Connections << Grant::Adapter::Pg.new(
  name: "replica", 
  url: ENV["REPLICA_DATABASE_URL"]
)

# Analytics database
Grant::Connections << Grant::Adapter::Pg.new(
  name: "analytics",
  url: ENV["ANALYTICS_DATABASE_URL"]
)
```

## Database Setup

### PostgreSQL Setup

```sql
-- Create user
CREATE USER grant_user WITH PASSWORD 'your_password';

-- Create database
CREATE DATABASE grant_db;

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE grant_db TO grant_user;

-- For UUID support (optional)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
```

### MySQL Setup

```sql
-- Create user
CREATE USER 'grant_user'@'localhost' IDENTIFIED BY 'your_password';

-- Create database
CREATE DATABASE grant_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Grant privileges
GRANT ALL PRIVILEGES ON grant_db.* TO 'grant_user'@'localhost';
FLUSH PRIVILEGES;
```

### SQLite Setup

SQLite requires minimal setup:

```bash
# Create database file (automatic when connecting)
touch ./database.db

# Ensure SQLite version is 3.24.0+
sqlite3 --version
```

## Testing Your Setup

Create a simple model to verify your installation:

```crystal
require "grant/adapter/pg" # or mysql, sqlite

class TestModel < Grant::Base
  connection pg # Use your connection name
  table test_models
  
  column id : Int64, primary: true
  column name : String
  timestamps
end

# Test the connection
begin
  TestModel.first
  puts "✅ Database connection successful!"
rescue ex
  puts "❌ Connection failed: #{ex.message}"
end
```

## Development vs Production

### Development Environment

For development, you can use a simple `.env` file:

```bash
# .env
DATABASE_URL=postgresql://localhost/grant_dev
TEST_DATABASE_URL=postgresql://localhost/grant_test
```

Load it in your application:

```crystal
# Load .env in development
if ENV["CRYSTAL_ENV"]? != "production"
  require "dotenv"
  Dotenv.load
end
```

### Production Environment

For production deployments:

1. **Use connection pooling** (handled automatically by Grant)
2. **Set appropriate timeouts** for your database
3. **Use SSL connections** when possible
4. **Configure read replicas** for scaling

Example production configuration:

```crystal
Grant::Connections << Grant::Adapter::Pg.new(
  name: "primary",
  url: ENV["DATABASE_URL"],
  pool_size: ENV.fetch("DB_POOL_SIZE", "25").to_i,
  checkout_timeout: 5.seconds,
  retry_attempts: 3,
  retry_delay: 0.2.seconds
)
```

## Docker Setup

For containerized development, use the provided Docker configuration:

```yaml
# docker-compose.yml
version: '3.8'
services:
  db:
    image: postgres:14
    environment:
      POSTGRES_USER: grant
      POSTGRES_PASSWORD: password
      POSTGRES_DB: grant_db
    ports:
      - "5432:5432"
  
  app:
    build: .
    depends_on:
      - db
    environment:
      DATABASE_URL: postgresql://grant:password@db/grant_db
```

## Troubleshooting

### Common Issues

1. **SQLite version too old**: Grant requires SQLite 3.24.0+. Update your system's SQLite or use a newer Docker image.

2. **Connection refused**: Ensure your database server is running and accessible.

3. **Authentication failed**: Verify credentials and that the user has proper permissions.

4. **Shard installation fails**: Clear the cache with `rm -rf lib/ .shards/` and try again.

### Getting Help

- [GitHub Issues](https://github.com/amberframework/grant/issues)
- [Crystal Forum](https://forum.crystal-lang.org/)
- [Amber Gitter Chat](https://gitter.im/amberframework/amber)

## Next Steps

- [Create your first model](first-model.md)
- [Learn about CRUD operations](../core-features/crud-operations.md)
- [Explore querying](../core-features/querying-and-scopes.md)
- [Set up relationships](../core-features/relationships.md)