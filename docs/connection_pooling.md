# Connection pools, replicas and failover

This page documents the connection API that exists today. It supersedes the
sketches in `docs/infrastructure/database-scaling.md` for anything about pools.

## Establishing connections

```crystal
Grant::ConnectionRegistry.establish_connection(
  database: "primary",
  adapter: Grant::Adapter::Pg,
  url: "postgres://localhost/app",
  role: :writing,
  pool_size: 25,
  checkout_timeout: 5.seconds,
)
```

Or from a model: `User.establish_connection(url: "...", adapter: Grant::Adapter::Pg, pool_size: 10)`.
Establishing a key that already exists replaces the connection and closes the
old pool.

| Option | Default | Meaning |
| --- | --- | --- |
| `pool_size` | 25 | Most connections the pool opens |
| `initial_pool_size` | 2 | Connections opened up front (capped at `pool_size`) |
| `max_idle_pool_size` | `pool_size` for PostgreSQL and MySQL, driver default (1) for SQLite | Idle connections kept; a burst reuses them instead of reconnecting |
| `checkout_timeout` | 5 s | How long a fiber waits for a connection before `Grant::ConnectionTimeoutError` |
| `retry_attempts` / `retry_delay` | 1 / 0.2 s | Retries of a refused connection, and of one lost read, with exponential backoff capped at 5 s |
| `idle_timeout`, `min_connections`, `keepalive`, `max_age`, `reaping_frequency` | off | Opt-in reaper (see below) |
| `prepared_statements` | `true` | `false` for PgBouncer in transaction mode (SQLite always prepares) |
| `statement_limit` | 1000 | Prepared statements cached per connection; 0 disables the cache |

A SQLite `:memory:` database always gets a pool of one connection, because a
second connection would be a different, empty database.

## Retries

* A refused connection is retried up to `retry_attempts` times.
* A connection lost during a plain read (`SELECT`, `SHOW`, `EXPLAIN`, `VALUES`)
  outside a transaction is retried once.
* A lost write, a `WITH` statement, a call without SQL and anything inside a
  transaction is never retried: it raises `Grant::ConnectionFailed`, because the
  server may already have applied it.

## Inspecting and tearing down

```crystal
User.connection_pool.stat  # => PoolStat(size: 25, connections: 3, busy: 1, idle: 2, waiting: 0, ...)
User.connected?            # pool established and answering SELECT 1
Grant::ConnectionRegistry.pool_stats
Grant::ConnectionRegistry.remove_connection("primary", :reading, replica_index: 1)
Grant::ConnectionRegistry.disconnect_all!  # close every pool; each reopens on next use
```

`stat` reads the driver pool's counters and atomics and takes no lock. Pools are
always closed after the registry lock is released.

`Adapter#active?`, `#verify!` (raises `Grant::ConnectionFailed`) and
`#reconnect!` are the liveness API; `Grant::ConnectionRegistry.verify!` also
updates the health monitor, so a recovered connection is used again at once.

## Reaper

With `idle_timeout`, `keepalive` or `max_age` set, a `Grant::PoolReaper` wakes
every `reaping_frequency` (default one minute). It closes idle connections down
to `min_connections` once nothing was checked out for `idle_timeout`, retires
idle connections open longer than `max_age`, and runs `SELECT 1` on idle
connections every `keepalive`. A connection that passes `max_age` while checked
out is closed when it is returned. The reaper never holds the pool's mutex
during I/O.

## Replicas

```crystal
Grant::ConnectionRegistry.establish_replicas(
  database: "primary", adapter: Grant::Adapter::Pg,
  urls: ["postgres://replica-a/app", "postgres://replica-b/app"])

class ApplicationRecord < Grant::Base
  configure_connection(load_balancing_strategy: Grant::LeastConnectionsStrategy.new)
end
```

Strategies: `RoundRobinStrategy` (default), `RandomStrategy`,
`LeastConnectionsStrategy` (fewest connections checked out right now),
`WeightedStrategy` (register replicas with `replica_weight:`). Choosing a
replica reads an immutable list and allocates nothing.

`get_adapter` health checks every role. An unhealthy connection is skipped for
the next in its chain: reading, then writing, then primary. When nothing is
healthy it returns the requested connection so the caller sees the real error.

## Pinning one connection

```crystal
User.with_connection do |raw|
  raw.exec("CREATE TEMP TABLE scratch (id INTEGER)")
  User.connection.execute("INSERT INTO scratch VALUES (1)")
end
```

Every Grant statement of the fiber on that adapter, and any transaction opened
inside the block, uses the pinned connection. The block holds a pool connection
for its whole run: keep slow non-database work out of it.
