# CI Configuration Documentation

## Overview

The Grant ORM CI pipeline has been updated to support modern Crystal versions and comprehensive testing of multiple database configurations, including sharding and failover scenarios.

## Workflows

### 1. Main Test Suite (`spec.yml`)

The main workflow runs on every push and pull request.

#### Updates:
- **Crystal Versions**: Updated from old versions (1.6.2-1.8.1) to modern versions (1.14.0-latest)
- **GitHub Actions**: Updated to use latest action versions (v4)
- **Database Services**: Added separate primary and replica instances for each database type
- **Timeout**: Increased from 2 to 5 minutes for more complex tests

#### Test Matrix:
- **SQLite**: Tests with in-memory and file-based replicas
- **MySQL**: Tests with MySQL 8.0 primary and replica on different ports
- **PostgreSQL**: Tests with PostgreSQL 16 primary and replica instances

### 2. Sharding Tests (`sharding.yml`)

Dedicated workflow for testing sharding functionality.

#### Features:
- Runs only when sharding-related files change
- Sets up 4 PostgreSQL shards (0-3) with primary and replica for each
- Sets up 2 MySQL shards for cross-database testing
- Includes configuration database for shard mapping

#### Environment Variables:
```bash
# PostgreSQL Sharding
CONFIG_DATABASE_URL: postgres://granite:password@localhost:5400/config_db
SHARD_0_PRIMARY: postgres://granite:password@localhost:5410/shard_0
SHARD_0_REPLICA: postgres://granite:password@localhost:5411/shard_0
# ... (continues for shards 1-3)

# MySQL Sharding
CONFIG_DATABASE_URL: mysql://granite:password@localhost:3300/config_db
SHARD_0_PRIMARY: mysql://granite:password@localhost:3310/shard_0
SHARD_1_PRIMARY: mysql://granite:password@localhost:3320/shard_1
```

### 3. Failover Tests (`failover.yml`)

Tests connection failover and recovery scenarios.

#### Features:
- Tests automatic failover from primary to replica
- Simulates connection failures
- Tests recovery mechanisms
- Multiple replica support

## Running Tests Locally

### Basic Tests
```bash
# SQLite
CURRENT_ADAPTER=sqlite SQLITE_DATABASE_URL=sqlite3:./test.db crystal spec

# PostgreSQL
CURRENT_ADAPTER=pg PG_DATABASE_URL=postgres://user:pass@localhost/db crystal spec

# MySQL
CURRENT_ADAPTER=mysql MYSQL_DATABASE_URL=mysql://user:pass@localhost/db crystal spec
```

### Sharding Tests
```bash
# Set up multiple database URLs
export SHARD_0_PRIMARY=postgres://user:pass@localhost:5410/shard_0
export SHARD_1_PRIMARY=postgres://user:pass@localhost:5420/shard_1
crystal spec spec/granite/composite_primary_key_spec.cr
```

## Adding New Tests

### For Sharding Features
1. Add test files matching `*sharding*` or `*composite*` pattern
2. Tests will automatically run in the sharding workflow
3. Use the shard-specific database URLs in tests

### For Connection Features
1. Add test files matching `*connection*` or `*failover*` pattern
2. Tests will run in the failover workflow
3. Test both primary and replica connections

## Troubleshooting

### Common Issues

1. **Old Crystal Version Errors**
   - Ensure your code is compatible with Crystal 1.14.0+
   - Use `--ignore-crystal-version` flag for development

2. **Database Connection Failures**
   - Check that all required environment variables are set
   - Ensure database services are healthy before running tests

3. **Timeout Issues**
   - Complex tests may need longer timeouts
   - Adjust `timeout-minutes` in workflow files

## Future Improvements

1. **Add Replication Setup**
   - Configure actual primary-replica replication
   - Test real failover scenarios

2. **Performance Benchmarks**
   - Add benchmark jobs for sharding overhead
   - Compare single vs multi-database performance

3. **Chaos Testing**
   - Random connection failures
   - Network partition simulation
   - Load testing with sharding