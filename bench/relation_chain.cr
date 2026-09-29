# bench/relation_chain.cr
#
# Measures what immutable relation chaining costs compared with the previous
# behavior, where every chain method mutated one shared builder.
#
# The "mutating" arm calls the bang variants (`where!`, `order!`, ...) on a single
# builder, which is exactly what the old chain methods did. The "immutable" arm
# uses the public chain methods, which copy-on-write. Both build the same SQL.
# Nothing touches the database; a connection is registered only so the model can
# resolve its adapter.
#
# Usage:
#   CURRENT_ADAPTER=sqlite crystal-alpha run --release bench/relation_chain.cr
#
# Prints heap bytes allocated per chain for each arm and the ratio (the
# guardrail is <= 1.2x), plus wall-clock time.

require "./bench_helper"

Bench.setup!("/tmp/grant_bench_relation_chain.db")

alias Todo = Bench::Todo

ITERATIONS = 20_000

def bytes_allocated(& : ->) : UInt64
  GC.collect
  before = GC.stats.total_bytes
  yield
  GC.stats.total_bytes - before
end

def sink(value) : Nil
  # Keep the optimizer from discarding the built relation.
  STDERR.print("") if value.to_s.empty?
end

chains = {
  "where.order.limit"                       => {
    mutating:  -> { Todo.where(tenant_id: 7_i64).order!(:created_at).limit!(50) },
    immutable: -> { Todo.where(tenant_id: 7_i64).order(:created_at).limit(50) },
  },
  "where x3.order.limit.offset"             => {
    mutating:  -> { Todo.where(tenant_id: 7_i64).where!(done: false).where!("title != ?", "x").order!(:created_at).limit!(50).offset!(100) },
    immutable: -> { Todo.where(tenant_id: 7_i64).where(done: false).where("title != ?", "x").order(:created_at).limit(50).offset(100) },
  },
  "where.order.group_by.having.limit"       => {
    mutating:  -> { Todo.where(tenant_id: 7_i64).order!(:created_at).group_by!(:done).having!("COUNT(*) > ?", 1).limit!(10) },
    immutable: -> { Todo.where(tenant_id: 7_i64).order(:created_at).group_by(:done).having("COUNT(*) > ?", 1).limit(10) },
  },
  "where.joins.order.distinct.limit"        => {
    mutating:  -> { Todo.where(tenant_id: 7_i64).joins!("users", on: "users.id = todos.tenant_id").order!(:created_at).distinct!.limit!(10) },
    immutable: -> { Todo.where(tenant_id: 7_i64).joins("users", on: "users.id = todos.tenant_id").order(:created_at).distinct.limit(10) },
  },
}

puts "Grant relation chain benchmark (#{ITERATIONS} chains per arm)"
puts
puts "%-38s %14s %14s %8s %12s %12s" % {"chain", "mutating B/op", "immutable B/op", "ratio", "mut ms", "imm ms"}

worst = 0.0
chains.each do |name, arms|
  mutating = arms[:mutating]
  immutable = arms[:immutable]

  # Warm up so lazy initialization is not charged to either arm.
  100.times { sink(mutating.call); sink(immutable.call) }

  mutating_bytes = 0_u64
  immutable_bytes = 0_u64
  mutating_span = Time.measure do
    mutating_bytes = bytes_allocated { ITERATIONS.times { sink(mutating.call) } }
  end
  immutable_span = Time.measure do
    immutable_bytes = bytes_allocated { ITERATIONS.times { sink(immutable.call) } }
  end

  ratio = immutable_bytes.to_f / mutating_bytes.to_f
  worst = ratio if ratio > worst
  puts "%-38s %14.0f %14.0f %7.2fx %12.1f %12.1f" % {
    name,
    mutating_bytes.to_f / ITERATIONS,
    immutable_bytes.to_f / ITERATIONS,
    ratio,
    mutating_span.total_milliseconds,
    immutable_span.total_milliseconds,
  }
end

puts
puts "worst ratio: %.2fx (guardrail 1.20x)" % worst
exit(worst <= 1.2 ? 0 : 1)
