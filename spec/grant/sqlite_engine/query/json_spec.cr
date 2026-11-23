require "spec"
require "../../../support/sqlite_engine/query_oracle"

# The JSON functions compared with C SQLite: every document below under
# every path, through json_extract, json_type, ->, ->>, json(),
# json_valid(), json_array_length(), json_error_position(), and json_each
# / json_tree rows (keys, values, types, ids, parents and paths).
module JsonSpecFixture
  alias V = Grant::SQLiteEngine::Value

  DOCUMENTS = [
    %({"a":1,"b":[1,2,{"c":"x"}],"d":{"e":null,"f":true,"g":false},"h":1.5,"i":-0,"j":"q\\"u\\u00e9\\n"}),
    %([1, 2.0, -3e2, "four", [5, [6]], {"seven": 7}, null, true, false]),
    %(  {"theme" : "dark", "notifications": {"email": true, "sms": false}, "tags": ["a", "b"], "n": 12345678901234567890}  ),
    %({"a b":1,"a.b":2,"":3,"\\u0041":4,"é":5,"x":{"y":{"z":[[1,2],[3,[4,5]]]}}}),
    %({a: 1, 'b': 'two', c: [1,2,], d: 0x1F, e: -0X10, f: .5, g: 5., h: +7, i: Infinity, j: -inf, k: NaN, /* c */ l: 'it\\'s', m: "\\x41\\v\\0"} // end),
    %([0x7FFFFFFFFFFFFFFF, 0x8000000000000000, 0xFFFFFFFFFFFFFFFFF, 9223372036854775807, 9223372036854775808, -9223372036854775808, -9223372036854775809, 1e400, -1e400, 0.1, 1E+2, 1e-2]),
    %("just text"),
    %(42),
    %(-3.25),
    %(null),
    %(true),
    %([]),
    %({}),
    %([[[]]]),
    %({"dup":1,"dup":2}),
    %(["a\\u0000b", "tab\\there", "\\ud83d\\ude00", "\\ud83d", "control\u0001"]),
    %({"a":1} x),
    %([1,2),
    %({"a" 1}),
    %({"a":01}),
    %([1,,2]),
    %(),
    %(   ),
    %(nul),
    %([1 2]),
    %({"a":1,}),
    %([.e1]),
    %(\u00a0[1]\u2028),
    %("unterminated),
    %(['\\q']),
    %({"k\\"q":1, "k\\u0022r": 2}),
    %([-0x0, -.5, -5., 00, -01]),
  ]

  PATHS = [
    "$", "$.a", "$.b", "$.b[0]", "$.b[2].c", "$.b[#]", "$.b[#-1]", "$.b[#-1].c", "$.b[#-9]", "$.b[9]", "$[0]", "$[1]",
    "$[4][1][0]", "$[#-1]", "$.d.e", "$.d.f", "$.d.g", "$.h", "$.i", "$.j", "$.notifications.email", "$.\"a b\"",
    "$.\"a.b\"", "$.\"\"", "$.A", "$.\"A\"", "$.\"\\u0041\"", "$.é", "$.x.y.z[1][1][0]", "$.a.b", "$.dup", "$.\"k\\\"q\"",
    "$.\"k\\u0022r\"", "$.k\"q", "$.d", "$.e", "$.f", "$.g", "$.k", "$.l", "$.m", "$.n", "$.tags[1]", "$.theme",
    "a", "$a", "$.", "$[", "$[x]", "$[1", "$.\"open", "$[#-]", "$[-1]", "",
  ]

  ABBREVIATED = ["a", "b", "0", "-1", "[0]", "$.a", "a b", "x.y", "theme", "tags", "é"]

  def self.queries : Array({String, Array(V)})
    list = [] of {String, Array(V)}
    DOCUMENTS.each do |document|
      list << {"SELECT json(?), json_type(?), json_valid(?), json_valid(?, 2), json_valid(?, 6), json_array_length(?), json_error_position(?)",
               Array(V).new(7, document)}
      list << {"SELECT key, value, type, atom, id, parent, fullkey, path FROM json_each(?)", [document] of V}
      list << {"SELECT key, value, type, atom, id, parent, fullkey, path FROM json_tree(?)", [document] of V}
      PATHS.each do |path|
        list << {"SELECT json_extract(?1, ?2), json_type(?1, ?2), ?1 -> ?2, ?1 ->> ?2, json_array_length(?1, ?2)", [document, path] of V}
        list << {"SELECT key, value, type, atom, id, parent, fullkey, path FROM json_each(?1, ?2)", [document, path] of V}
        list << {"SELECT key, value, type, atom, id, parent, fullkey, path FROM json_tree(?1, ?2)", [document, path] of V}
      end
      ABBREVIATED.each do |path|
        list << {"SELECT ?1 -> ?2, ?1 ->> ?2", [document, path] of V}
      end
      list << {"SELECT ?1 -> 0, ?1 ->> 1, ?1 -> -1, ?1 ->> -2", [document] of V}
      list << {"SELECT json_extract(?1, '$.a', '$.b', '$[0]', '$.nope')", [document] of V}
    end
    [
      "SELECT json(NULL), json_extract(NULL, '$'), json_type(NULL), json_valid(NULL), json_array_length(NULL), json_error_position(NULL)",
      "SELECT json_extract('{\"a\":1}', NULL), json_type('{\"a\":1}', NULL), json_extract('{\"a\":1}')",
      "SELECT json_extract('{\"a\":1}', '$.a', NULL)",
      "SELECT json(5), json(1.5), json(x'5b315d'), json_type(x'7b7d'), json(x'01'), json_type(x'13'), json(x'00'), json_valid(x'00', 4)",
      "SELECT json_valid('{}', 0)", "SELECT json_valid('{}', 16)", "SELECT json_valid(x'0c', 8), json_valid(x'1b31', 8), json_valid('[1]', 4)",
      "SELECT * FROM json_each('[1,2]') WHERE value > 1",
      "SELECT * FROM json_each('[1,2]', 'a')",
      "SELECT * FROM json_each('{')",
      "SELECT * FROM json_each(NULL)",
      "SELECT * FROM json_tree('{\"a\":[1,{\"b\":2}]}', '$.a')",
      "SELECT count(*) FROM json_each('[1,2,3]') AS j WHERE j.type = 'integer'",
      "SELECT t.x, j.value FROM (SELECT 1 AS x UNION ALL SELECT 2) t, json_each('[10,20]') j ORDER BY 1, 2",
      "SELECT EXISTS (SELECT 1 FROM json_each('[{\"a\":1},{\"a\":2}]', '$') AS e WHERE CASE WHEN e.type = 'object' THEN (json_extract(e.value, '$.a') = 2) ELSE 0 END)",
      "SELECT json_extract('[1,2]', '$[1]') + 1, typeof(json_extract('{\"a\":[1]}', '$.a')), typeof('[1]' -> '$'), typeof('[1]' ->> '$')",
      "SELECT json_type('{\"a\":1}', 'x'), json_type('{\"a\":1}', '$.a.b')",
    ].each { |sql| list << {sql, [] of V} }
    list
  end
end

describe "Grant::SQLiteEngine::Query JSON functions" do
  directory = Path[Dir.tempdir] / "grant-json-spec-#{Process.pid}"
  Dir.mkdir_p(directory)
  path = (directory / "fixture.db").to_s
  oracle = SQLiteQueryOracle::Connection.new(path)
  if message = oracle.exec("CREATE TABLE t (x)")
    raise "fixture setup failed: #{message}"
  end
  database = Grant::SQLiteEngine::Database.open(path)
  session = Grant::SQLiteEngine::Query::Session.new(database)

  # The engine follows C SQLite 3.51.0, and older libraries render and
  # validate JSON differently (JSON5 escapes, control characters, integer
  # overflow, negative array indexes after ->), so the comparison needs that
  # library or a newer one.
  library_version = SQLiteSQLOracle.version.split(" ").first
  if library_version.split(".").map(&.to_i) < [3, 51, 0]
    pending "matches C SQLite 3.51.0 on every document, path and function (the linked libsqlite3 is #{library_version})"
    next
  end

  it "matches C SQLite on every document, path and function" do
    failures = [] of String
    JsonSpecFixture.queries.each do |(sql, parameters)|
      expected = oracle.query(sql, parameters)
      actual = begin
        SQLiteQueryOracle.engine_query(session, sql, parameters)
      rescue error : Exception
        SQLiteQueryOracle::Outcome.new([] of String, [] of Array(JsonSpecFixture::V), "raised #{error.class}: #{error.message}", [] of Bool)
      end
      if difference = SQLiteQueryOracle.difference(expected, actual, ordered: !sql.includes?("json_each(") || sql.includes?("ORDER BY"))
        failures << "#{sql} #{parameters.inspect}\n    #{difference}"
      end
    end
    failures.first(60).should eq([] of String)
  end
end
