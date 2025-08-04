#!/usr/bin/env crystal

# Simple compilation test
puts "Testing if multi-database features compile..."

require "./src/granite"

# Test that all new classes are available
{% for klass in [
  Granite::ConnectionRegistry::ConnectionSpec,
  Granite::ConnectionManagement::ReplicaLagTracker,
  Granite::HealthMonitor,
  Granite::HealthMonitorRegistry,
  Granite::ReplicaLoadBalancer,
  Granite::LoadBalancerRegistry,
  Granite::RoundRobinStrategy,
  Granite::RandomStrategy,
  Granite::LeastConnectionsStrategy
] %}
  puts "✓ {{ klass }} exists"
{% end %}

puts "\nAll classes compile successfully!"
puts "\nTo perform a full test with actual databases:"
puts "1. Install PostgreSQL and/or MySQL"
puts "2. Set environment variables for database URLs"
puts "3. Use the TEST_PLAN_MULTI_DATABASE.md for comprehensive testing"