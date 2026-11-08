require "spec"

{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "../spec_helper"

describe Grant::PG::Connection, "#escape_pg_driver_literal" do
  it { escape_pg_driver_literal(%(foo)).should eq(%('foo')) }
  it { escape_pg_driver_literal(%(this has a \\)).should eq(%( E'this has a \\\\')) }
  it { escape_pg_driver_literal(%(what's your "name")).should eq(%('what''s your "name"')) }
  it { escape_pg_driver_literal(%(foo).to_slice).should eq(%('\\x666f6f')) }
  # it "raises on invalid strings" do
  #  expect_raises(Grant::PG::ConnectionError) { escape_pg_driver_literal("\u{F4}") }
  # end
end

describe Grant::PG::Connection, "#escape_pg_driver_identifier" do
  it { escape_pg_driver_identifier(%(foo)).should eq(%("foo")) }
  it { escape_pg_driver_identifier(%(what's \\ your "name")).should eq(%("what's \\ your ""name""")) }
  # it "raises on invalid strings" do
  #  expect_raises(Grant::PG::ConnectionError) { escape_pg_driver_identifier("\u{F4}") }
  # end
end
