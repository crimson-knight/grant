require "./probe_support"

def assert_open_exec_result(value : T) forall T
  {% unless T == DB::ExecResult %}
    {% raise "Adapter#open with DB::Connection#exec must return DB::ExecResult" %}
  {% end %}
end

adapter = Grant::Adapter::Sqlite.new("api_card_probe", ":memory:")
assert_open_exec_result(adapter.open { |database| database.exec("SELECT 1") })
