require "spec"
require "../../../support/sqlite_engine/query_oracle"

# The JSON functions that build and edit JSON, compared with C SQLite
# 3.51.0: json_array, json_object, json_quote, json_set, json_insert,
# json_replace, json_remove, json_patch, json_pretty, json_group_array,
# json_group_object and the jsonb_ forms (results compare byte for byte).
module JsonWriteSpecFixture
  alias V = Grant::SQLiteEngine::Value

  DOCUMENT = %({"a":1,"b":[1,2,{"c":"x"}],"d":{"e":null},"s":"q\\"u\\u00e9","n":1.50,"big":12345678901234567890})
  LONG     = %({"a":"a value long enough that the text result passes one hundred bytes","b":[10,20,30,40,50,60,70,80,90],"c":{"d":"x\\"y"}})

  CONSTRUCTORS = [
    "SELECT json_array(), json_array(1, 2.5, 'x', NULL), json_array('q\"uote', 'it''s', 'tab' || char(9) || char(1)), json_array('[1]', json('[1]'), json_array(1))",
    "SELECT json_array(1e999, -1e999, 0.1, 1e15, 1e16, -0.0, 9223372036854775807, 123456789012345680.0, 1.0)",
    "SELECT json_array(x'1331'), json_array(jsonb('{\"a\":[1]}')), json_array('a' || char(0) || 'b')",
    "SELECT json_array(x'ff')",
    "SELECT json_object(), json_object('a', 1, 'b', 'two', 'c', NULL, 'd', json('[1]'), 'e', '[1]', 'f', 2.50)",
    "SELECT json_object('a', json_object('b', json_array(1, json_quote('x'))), 'k\"q', 1, '', 2, 'é', 3)",
    "SELECT json_object('a')",
    "SELECT json_object(1, 2)",
    "SELECT json_object(NULL, 2)",
    "SELECT json_object('a', x'ff')",
    "SELECT json_quote('x\"y'), json_quote(3.5), json_quote(NULL), json_quote(7), json_quote(json('[1, 2]')), json_quote('[1, 2]'), json_quote(1e999)",
    "SELECT json_quote(x'ff')",
    "SELECT json_quote()",
    "SELECT subtype(json_array(1)), subtype(json_object('a', 1)), subtype(json_quote(1)), subtype(jsonb_array(1)), subtype(jsonb_object('a', 1))",
    "SELECT typeof(json_array(1)), typeof(jsonb_array(1)), typeof(jsonb_object('a', 1)), typeof(jsonb('1'))",
    "SELECT json_array(CASE WHEN 1 THEN json('[1]') END, coalesce(NULL, json('{}')), iif(1, json('2'), 3), json('[3]') || '', '{\"a\":[5]}' -> '$.a', '{\"a\":[5]}' ->> '$.a')",
    "SELECT json_array(x) FROM (SELECT json('[1]') AS x)",
    "SELECT hex(jsonb_array()), hex(jsonb_array(1, 'x', NULL, 2.5, json('{\"a\":[true,false]}'))), hex(jsonb_object('a', 1, 'b', json_array(1, 'q\"'))), hex(jsonb('  [1, 2.0, \"x\\ny\", {a:0x10}]  '))",
    "SELECT jsonb(x'1331'), jsonb(NULL), jsonb('[1'), jsonb(5)",
    "SELECT jsonb('[1')",
  ]

  EDITS = [
    "SELECT json_set(?1, '$.a', 2), json_set(?1, '$.z', 'new'), json_set(?1, '$.b[0]', NULL), json_set(?1, '$.b[#]', 9), json_set(?1, '$.b[#-1]', json('[]')), json_set(?1, '$.d.e.f', 1)",
    "SELECT json_insert(?1, '$.a', 2), json_insert(?1, '$.z', 'new'), json_insert(?1, '$.b[#]', 9), json_insert(?1, '$.b[7]', 9), json_insert(?1, '$.x.y.z', 1), json_insert(?1, '$.x[0].y', 1), json_insert(?1, '$.x[1]', 1)",
    "SELECT json_replace(?1, '$.a', 2), json_replace(?1, '$.z', 'new'), json_replace(?1, '$.b[2].c', 1.5), json_replace(?1, '$', 5), json_replace(?1, '$.b[#-1]', 'last')",
    "SELECT json_set(?1, '$.a', 2, '$.a', 3, '$.z', json('{\"y\":1}'), '$.z.y', 'deep'), json_set(?1, NULL, 1, '$.a', 7), json_set(?1, '$.\"k q\"', 1, '$.\"e\\\"s\"', 2, '$.\"\\u0061\"', 3)",
    "SELECT json_set(?1), json_insert(?1), json_replace(?1), json_remove(?1), json_set(), json_insert(), json_replace(), json_remove(), json_set(NULL, '$.a', 1), json_remove(NULL, '$.a')",
    "SELECT json_set(?1, '$', 'whole'), json_insert(?1, '$', 'whole'), json_set(?1, '$.a', '[1]'), json_set(?1, '$.a', json('[1]')), json_set(?1, '$.a', x'1331'), json_set(?1, '$.a', 1e999)",
    "SELECT json_remove(?1, '$.a'), json_remove(?1, '$.b[0]', '$.b[0]'), json_remove(?1, '$.b[#-1]'), json_remove(?1, '$.nope'), json_remove(?1, '$'), json_remove(?1, NULL), json_remove(?1, '$.d.e', '$.d')",
    "SELECT subtype(json_set(?1, '$.a', 1)), subtype(jsonb_set(?1, '$.a', 1)), subtype(json_remove(?1, '$.a')), subtype(json_patch(?1, '{}')), subtype(json_pretty(?1)), typeof(jsonb_remove(?1, '$.a'))",
    "SELECT hex(jsonb_set(?1, '$.a', 2)), hex(jsonb_set(?1, '$.s', 'x')), hex(jsonb_insert(?1, '$.z', 'q\"')), hex(jsonb_replace(?1, '$.b', 1)), hex(jsonb_remove(?1, '$.b[1]')), hex(jsonb_set(?1, '$', '12345'))",
    "SELECT hex(jsonb(json_set(?1, '$.z', 'q\"uote'))), hex(jsonb(json_remove(?1, '$.b'))), hex(jsonb_set(json_set(?1, '$.s', 'x'), '$.n', 1)), hex(jsonb_extract(json_replace(?1, '$.b', 'short'), '$'))",
    "SELECT json_patch(?1, '{\"a\":null,\"z\":{\"y\":null,\"x\":1},\"d\":{\"e\":2}}'), json_patch(?1, '[1]'), json_patch('[1,2]', '{\"a\":1}'), json_patch(?1, NULL), json_patch(NULL, ?1), json_patch('{\"a\":{\"b\":1,\"c\":2}}', '{\"a\":{\"b\":null}}')",
    "SELECT hex(jsonb_patch(?1, '{\"a\":null,\"z\":{\"y\":null,\"x\":1},\"big\":7}')), hex(jsonb_patch('5', '{\"a\":{\"b\":1}}')), json_patch('{\"a\":1}', '{\"\\u0061\":2}'), json_patch('{a:1}', '{\"a\":null}')",
    "SELECT json_pretty(?1), json_pretty(?1, '  '), json_pretty(?1, char(9)), json_pretty(?1, NULL), json_pretty('[]'), json_pretty('{}'), json_pretty('[[],{}]'), json_pretty(5), json_pretty(NULL)",
    "SELECT jsonb_extract(?1, '$.a'), hex(jsonb_extract(?1, '$.b')), hex(jsonb_extract(?1, '$.a', '$.b')), jsonb_extract(?1, '$.nope'), jsonb_extract(?1, '$.s'), jsonb_extract(?1), subtype(jsonb_extract(?1, '$.b'))",
    "SELECT json_valid(json_set(?1, '$.a', 1)), json_type(json_remove(?1, '$.a'), '$.b'), json_array_length(json_set(?1, '$.b[#]', 1), '$.b'), json_extract(json_patch(?1, '{\"q\":[1]}'), '$.q')",
  ]

  ERRORS = [
    "SELECT json_set(?1, '$.a')", "SELECT json_insert(?1, '$.a')", "SELECT json_replace(?1, '$.a')", "SELECT jsonb_set(?1, '$.a')",
    "SELECT json_set(?1, 'a', 1)", "SELECT json_set(?1, '$[', 1)", "SELECT json_set(?1, '$.', 1)", "SELECT json_set(?1, '$.\"open', 1)",
    "SELECT json_set(?1, '$.b[x]', 1)", "SELECT json_set(?1, '$.new[x]', 1)", "SELECT json_set(?1, '$.it''s[', 1)", "SELECT json_set(?1, 5, 1)",
    "SELECT json_remove(?1, 'a')", "SELECT json_remove(?1, '$.b[')", "SELECT json_remove(?1, '$.a', 7)", "SELECT json_remove('{', '$.a')",
    "SELECT json_set('{', '$.a', 1)", "SELECT json_set('', '$.a', 1)", "SELECT json_set(?1, '$.a', x'ff')", "SELECT json_set(x'ff', '$.a', 1)",
    "SELECT json_patch('{', '{}')", "SELECT json_patch('{}', '{')", "SELECT json_patch('{}')", "SELECT json_pretty('{')", "SELECT json_pretty()",
    "SELECT jsonb_extract(?1, 'a')", "SELECT jsonb_extract(?1, '$[')", "SELECT json_group_array()", "SELECT json_group_object(1)",
    "SELECT json_group_array(x'ff')", "SELECT json_group_object('a', x'ff')", "SELECT json_group_array(1) OVER ()",
  ]

  AGGREGATES = [
    "SELECT json_group_array(v), json_group_object(k, v) FROM t",
    "SELECT json_group_array(json(j)), json_group_array(j), json_group_object(k, json(j)), json_group_object(id, j -> '$') FROM t",
    "SELECT k, json_group_array(id), json_group_object(v, r) FROM t GROUP BY k ORDER BY k",
    "SELECT json_group_array(v) FILTER (WHERE id > 2), json_group_object(k, id) FILTER (WHERE id < 0), json_group_array(DISTINCT k) FROM t",
    "SELECT json_group_array(v), json_group_object(k, v), jsonb_group_array(v), jsonb_group_object(k, v) FROM t WHERE id < 0",
    "SELECT typeof(jsonb_group_array(v)), typeof(jsonb_group_array(v)) FILTER (WHERE 0), subtype(json_group_array(v)), subtype(jsonb_group_array(v)), subtype(json_group_object(k, v)) FROM t",
    "SELECT hex(jsonb_group_array(v)), hex(jsonb_group_object(k, json(j))), hex(jsonb_group_array(b)) FROM t WHERE id < 4",
    "SELECT json_array(json_group_array(id)), json_quote(json_group_object(k, id)), json_set('{}', '$.all', json_group_array(r)), json_type(json_group_array(id)) FROM t",
    "SELECT json_group_object(NULL, v), json_group_object(r, v), json_group_object('a' || char(0) || 'b', id) FROM t WHERE id < 3",
    "SELECT id, json_set(j, '$.n', v), json_remove(j, '$.a'), json_array(v, r, b), json_object(coalesce(k, 'none'), json(j)) FROM t ORDER BY id",
  ]

  TABLE = <<-SQL
    CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT, v, j TEXT, r REAL, b BLOB);
    INSERT INTO t VALUES (1, 'a', 'one', '{"a":1,"b":[1,2]}', 1.5, x'1331');
    INSERT INTO t VALUES (2, 'b', 2, '[1,2,3]', -0.0, NULL);
    INSERT INTO t VALUES (3, 'a', NULL, '{"a":{"b":null},"n":"x\\"y"}', 1e300, x'0c');
    INSERT INTO t VALUES (4, NULL, 'q"uote', '"text"', NULL, x'cb1b31');
    INSERT INTO t VALUES (5, 'c d', 3.25, '{"a":[{"deep":[1,[2,[3]]]}],"é":"日本"}', 100.0, NULL);
    SQL

  def self.queries : Array({String, Array(V)})
    list = [] of {String, Array(V)}
    (CONSTRUCTORS + AGGREGATES).each { |sql| list << {sql, [] of V} }
    [DOCUMENT, LONG, "[1,[2,3],{\"a\":[]}]", "{}", "[]", "\"text\"", "{a:1,'b':[0x10,.5,],c:'it\\'s'}"].each do |document|
      (EDITS + ERRORS).each { |sql| list << {sql, [document] of V} }
    end
    list
  end

  # C's messages for the errors these functions raise.
  MESSAGES = {
    "SELECT json_object('a')"                     => "json_object() requires an even number of arguments",
    "SELECT json_object(1, 2)"                    => "json_object() labels must be TEXT",
    "SELECT json_array(x'ff')"                    => "JSON cannot hold BLOB values",
    "SELECT json_set('{}', '$.a')"                => "json_set() needs an odd number of arguments",
    "SELECT json_insert('{}', '$.a')"             => "json_insert() needs an odd number of arguments",
    "SELECT json_replace('{}', '$.a')"            => "json_replace() needs an odd number of arguments",
    "SELECT jsonb_set('{}', '$.a')"               => "json_set() needs an odd number of arguments",
    "SELECT json_set('{}', 'a', 1)"               => "bad JSON path: 'a'",
    "SELECT json_set('{}', '$.it''s[', 1)"        => "bad JSON path: '$.it''s['",
    "SELECT json_remove('[1]', '$[x]')"           => "bad JSON path: '$[x]'",
    "SELECT json_set('{', '$.a', 1)"              => "malformed JSON",
    "SELECT json_patch('{}', '{')"                => "malformed JSON",
    "SELECT json_set('{}', '$.a', x'ff')"         => "JSON cannot hold BLOB values",
    "SELECT json_quote()"                         => "wrong number of arguments to function json_quote()",
    "SELECT json_patch('{}')"                     => "wrong number of arguments to function json_patch()",
    "SELECT json_group_object(1) FROM (SELECT 1)" => "wrong number of arguments to function json_group_object()",
  }
end

describe "Grant::SQLiteEngine::Query JSON functions that build and edit JSON" do
  directory = Path[Dir.tempdir] / "grant-json-write-spec-#{Process.pid}"
  Dir.mkdir_p(directory)
  path = (directory / "fixture.db").to_s
  oracle = SQLiteQueryOracle::Connection.new(path)
  if message = oracle.exec(JsonWriteSpecFixture::TABLE)
    raise "fixture setup failed: #{message}"
  end
  session = Grant::SQLiteEngine::Query::Session.new(Grant::SQLiteEngine::Database.open(path))

  it "raises C's messages" do
    JsonWriteSpecFixture::MESSAGES.each do |sql, expected_message|
      SQLiteQueryOracle.engine_query(session, sql).error.should eq(expected_message)
    end
  end

  it "names window use of the JSON aggregates as unsupported" do
    expect_raises(Grant::SQLiteEngine::UnsupportedSQL, /window function json_group_array\(\)/) do
      session.prepare("SELECT json_group_array(id) OVER () FROM t")
    end
  end

  it "embeds text from a JSON function as JSON and other text as a string" do
    SQLiteQueryOracle.engine_query(session, "SELECT json_array('[1]', json('[1]')), json_object('a', '{}', 'b', json('{}'))").list_of_rows
      .should eq([[%(["[1]",[1]]), %({"a":"{}","b":{}})] of JsonWriteSpecFixture::V])
  end

  it "applies RFC 7396 in json_patch" do
    SQLiteQueryOracle.engine_query(session, %(SELECT json_patch('{"a":1,"b":2}', '{"b":null,"c":3}'))).list_of_rows
      .should eq([[%({"a":1,"c":3})] of JsonWriteSpecFixture::V])
  end

  # C keeps the subtype when the subquery's plan hands the value over in a
  # register (no sorter, no materialization); the engine's subquery rows are
  # plain values, so json_array((SELECT json('[1]'))) holds a string.
  pending "carries the JSON subtype out of a scalar subquery"

  library_version = SQLiteSQLOracle.version.split(" ").first
  if library_version.split(".").map(&.to_i) < [3, 51, 0]
    pending "matches C SQLite 3.51.0 on every statement (the linked libsqlite3 is #{library_version})"
    next
  end

  it "matches C SQLite on every constructor, edit, aggregate and error" do
    failures = [] of String
    JsonWriteSpecFixture.queries.each do |(sql, parameters)|
      expected = oracle.query(sql, parameters)
      actual = begin
        SQLiteQueryOracle.engine_query(session, sql, parameters)
      rescue error : Exception
        SQLiteQueryOracle::Outcome.new([] of String, [] of Array(JsonWriteSpecFixture::V), "raised #{error.class}: #{error.message}", [] of Bool)
      end
      # C has window functions; the engine names them as unsupported.
      next if sql.includes?(" OVER ")
      if difference = SQLiteQueryOracle.difference(expected, actual, ordered: true)
        failures << "#{sql} #{parameters.inspect}\n    #{difference}"
      end
    end
    failures.first(60).should eq([] of String)
  end
end
