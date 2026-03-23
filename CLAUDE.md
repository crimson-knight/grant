# Grant ORM

Grant is an ActiveRecord-pattern ORM for the Crystal programming language, targeting ~80-85% feature parity with Rails 8+ ActiveRecord. It replaces the older Granite ORM as part of the Amber framework ecosystem's V2 refresh.

## Project Identity

- **Name**: Grant (a personification, part of the Amber framework brand shift)
- **Pattern**: ActiveRecord (models inherit from `Grant::Base`)
- **Language**: Crystal (>= 1.6.0, < 2.0.0)
- **License**: MIT
- **Version**: 0.23.4

## Build and Test Commands

| Command | Description |
|---------|-------------|
| `shards install` | Install dependencies |
| `crystal spec` | Run full test suite (SQLite) |
| `crystal spec spec/grant/querying_spec.cr` | Run single spec file |
| `crystal tool format --check` | Check formatting |
| `crystal tool format` | Auto-format code |
| `crystal build src/grant.cr` | Compile library |
| `crystal docs -D grant_docs` | Generate API docs (includes Grant methods) |

## Key Directories

| Directory | Contents |
|-----------|----------|
| `src/grant/` | Core ORM source: base, columns, query builder, associations, validations, callbacks, etc. |
| `src/grant/query/` | Query::Builder, assemblers, WhereChain |
| `src/grant/locking/` | Optimistic and pessimistic locking |
| `src/grant/encryption/` | Encrypted attributes (AES-256-CBC with HMAC) |
| `src/grant/sharding/` | Horizontal sharding (experimental) |
| `src/grant/async/` | Async query operations |
| `src/grant/validators/` | Built-in validators (numericality, format, length, etc.) |
| `src/grant/validation_helpers/` | Quick validation macros |
| `src/adapter/` | Database adapters (pg, mysql, sqlite) |
| `spec/` | Test suite |
| `docs/` | Feature documentation (design reference, not published) |
| `examples/` | Working examples |

## Architecture Overview

### Core Components

- **Grant::Base** (`src/grant/base.cr`): Abstract base class all models inherit from. Includes columns, querying, callbacks, validations, associations, dirty tracking, and serialization modules via macros.

- **Connections** (`src/grant/connections.cr`): Connection registry. Adapters are registered via `Grant::Connections << adapter_instance` with a name. Models reference connections by name with the `connection` macro.

- **Columns** (`src/grant/columns.cr`): The `column` macro generates Crystal properties, DB mapping metadata, and serialization support. Supports converters for custom types.

- **Query::Builder** (`src/grant/query/`): Lazy, chainable query builder. Includes `Enumerable(Model)` so Crystal collection methods (map, select, reject, reduce, partition, etc.) work directly on query chains. Uses an assembler pattern to generate SQL for each database adapter.

- **Assembler Pattern**: Each database adapter has its own SQL assembler that translates the Query::Builder's abstract query representation into adapter-specific SQL (handling placeholder differences like `?` vs `$`, quoting, feature availability).

### Feature Modules

| Module | Purpose |
|--------|---------|
| `Grant::Associations` | belongs_to, has_one, has_many, has_many through, polymorphic |
| `Grant::Validators` | Validation framework and built-in validators |
| `Grant::Callbacks` | Lifecycle hooks (before/after save, create, update, destroy, validation) |
| `Grant::CommitCallbacks` | after_commit, after_rollback |
| `Grant::Dirty` | Attribute change tracking |
| `Grant::Locking::Optimistic` | Version-based optimistic locking |
| `Grant::Locking` | Pessimistic locking (FOR UPDATE, FOR SHARE, etc.) |
| `Grant::Transaction` | Transaction blocks with isolation levels and savepoints |
| `Grant::Encryption` | Transparent attribute encryption (deterministic and non-deterministic) |
| `Grant::SecureToken` | Cryptographic token generation |
| `Grant::SignedId` | Tamper-proof signed IDs |
| `Grant::TokenFor` | Data-invalidating temporary tokens |
| `Grant::Normalization` | Before-validation data normalization |
| `Grant::EnumAttributes` | Enum columns with scopes and helpers |
| `Grant::SerializedColumn` | JSON/YAML serialized columns |
| `Grant::ValueObjects` | Multi-column aggregation into structs |
| `Grant::Sharding::Model` | Horizontal sharding (experimental) |
| `Grant::Async` | Non-blocking query operations |

## Database Support

| Database | Driver Shard | Notes |
|----------|-------------|-------|
| PostgreSQL | `crystal-lang/crystal-pg` | Full feature support (arrays, JSONB, UUID, all lock modes) |
| MySQL | `crystal-lang/crystal-mysql` | Full support (JSON 5.7+, basic lock modes) |
| SQLite | `crystal-lang/crystal-sqlite3` | Local dev/testing, no row-level locking, requires >= 3.24.0 |

## Branch Convention

All branches follow: `feature/phase-{number}-{feature-group-name}` naming convention.

## Project Conventions

- When creating a work plan, **never estimate the time required**.
- **Local testing** is done using SQLite.
- **CI/CD testing** uses SQLite, PostgreSQL, and MySQL. The CI/CD pipeline runs on GitHub Actions.
- Grant uses Crystal **macros** extensively for its DSL (`column`, `connection`, `table`, `timestamps`, `scope`, `belongs_to`, `has_many`, `validates_*`, `before_*`, `after_*`, `encrypts`, `enum_attribute`, etc.). These generate code at compile time.
- Query::Builder is **lazy** -- queries do not execute until a terminal method is called.
- Query::Builder includes `Enumerable(Model)` -- standard Crystal collection methods work directly on query chains without calling `.all` first.
