require "../spec_helper"

# The rewrite this scanner replaced: one String#sub per placeholder. Kept here
# so the specs can prove both produce the same output for plain fragments.
private def legacy_numbered(clause : String, starting_index : Int32 = 0) : String
  if clause.includes?("?")
    clause.count("?").times do |i|
      clause = clause.sub("?", "$#{starting_index + i + 1}")
    end
  end
  clause
end

describe Grant::Adapter::PlaceholderScanner do
  pg = Grant::Adapter::Pg.new(name: "pg_placeholder", url: "postgres://localhost/unused")
  sqlite = Grant::Adapter::Sqlite.new(name: "sqlite_placeholder", url: "sqlite3::memory:")
  mysql = Grant::Adapter::Mysql.new(name: "mysql_placeholder", url: "mysql://localhost/unused")

  describe "numbering (PostgreSQL)" do
    it "numbers placeholders from 1" do
      pg.ensure_clause_template("a = ? AND b = ? AND c = ?").should eq("a = $1 AND b = $2 AND c = $3")
    end

    it "honors a starting index" do
      pg.ensure_clause_template("a = ? AND b = ?", 4).should eq("a = $5 AND b = $6")
    end

    it "returns a clause without placeholders unchanged" do
      clause = "SELECT * FROM users WHERE id = $1"
      pg.ensure_clause_template(clause).should be(clause)
    end

    it "matches the previous String#sub rewrite on plain fragments" do
      [
        "id = ?",
        "name = ? AND age = ? AND active = ?",
        "UPDATE users SET name = ?, age = ? WHERE id = ?",
        "name IS NULL AND age = ?",
        "café = ? AND ☃ = ?",
      ].each do |clause|
        pg.ensure_clause_template(clause).should eq(legacy_numbered(clause))
        pg.ensure_clause_template(clause, 3).should eq(legacy_numbered(clause, 3))
      end
    end
  end

  describe "quoted regions" do
    it "leaves a ? inside a single quoted literal alone and keeps numbering" do
      pg.ensure_clause_template("title = 'why?' AND id = ? AND slug = ?")
        .should eq("title = 'why?' AND id = $1 AND slug = $2")
    end

    it "treats a doubled quote as part of the literal" do
      pg.ensure_clause_template("note = 'it''s ok?' AND id = ?")
        .should eq("note = 'it''s ok?' AND id = $1")
    end

    it "leaves a ? inside a quoted identifier alone" do
      pg.ensure_clause_template(%(SELECT "what?" FROM t WHERE id = ?))
        .should eq(%(SELECT "what?" FROM t WHERE id = $1))
    end

    it "honors backslash escapes only in E strings" do
      pg.ensure_clause_template(%q(a = E'it\'s ?' AND b = ?)).should eq(%q(a = E'it\'s ?' AND b = $1))
      pg.ensure_clause_template(%q(a = 'x\' AND b = ?)).should eq(%q(a = 'x\' AND b = $1))
    end

    it "leaves a ? inside comments alone" do
      pg.ensure_clause_template("a = ? -- really?\nAND b = ?").should eq("a = $1 -- really?\nAND b = $2")
      pg.ensure_clause_template("a = ? /* why? /* nested? */ still? */ AND b = ?")
        .should eq("a = $1 /* why? /* nested? */ still? */ AND b = $2")
    end

    it "leaves a ? inside dollar quoted bodies alone" do
      pg.ensure_clause_template("SELECT $$is it?$$, ?").should eq("SELECT $$is it?$$, $1")
      pg.ensure_clause_template("SELECT $body$is it?$body$, ?").should eq("SELECT $body$is it?$body$, $1")
    end

    it "does not mistake $1 for a dollar quote" do
      pg.ensure_clause_template("a = $1 AND b = ? AND c = 'x?'").should eq("a = $1 AND b = $1 AND c = 'x?'")
    end

    it "handles an unterminated literal without failing" do
      pg.ensure_clause_template("a = ? AND b = 'oops ?").should eq("a = $1 AND b = 'oops ?")
    end
  end

  describe "PostgreSQL casts" do
    it "keeps :: casts and numbers the placeholders around them" do
      pg.ensure_clause_template("id::text = ? AND created_at::date > ?::date")
        .should eq("id::text = $1 AND created_at::date > $2::date")
    end

    it "keeps casts of quoted literals" do
      pg.ensure_clause_template("'2020-01-01'::date < ? AND '?'::text = ?")
        .should eq("'2020-01-01'::date < $1 AND '?'::text = $2")
    end
  end

  describe "?? escape" do
    it "turns ?? into a literal ? without consuming a parameter (PostgreSQL)" do
      pg.ensure_clause_template("data ?? 'key' AND id = ? AND kind = ?")
        .should eq("data ? 'key' AND id = $1 AND kind = $2")
    end

    it "supports the JSONB any-key and all-keys operators" do
      pg.ensure_clause_template("tags ??| array[?] AND tags ??& array[?]")
        .should eq("tags ?| array[$1] AND tags ?& array[$2]")
    end

    it "leaves ?? alone inside a quoted literal" do
      pg.ensure_clause_template("a = '??' AND b = ?").should eq("a = '??' AND b = $1")
    end

    it "collapses ?? on adapters with native ? placeholders" do
      sqlite.ensure_clause_template("a ?? b AND id = ?").should eq("a ? b AND id = ?")
      mysql.ensure_clause_template("a ?? b AND id = ?").should eq("a ? b AND id = ?")
    end

    it "escapes ? in raw where fragments built by the query builder" do
      sql = Parent.where("name ?? 'x' AND id = ?", 7_i64).raw_sql
      sql.should contain("name ? 'x' AND id = ")
    end

    it "runs a JSONB ?? operator through the query builder on PostgreSQL" do
      unless Parent.adapter.postgres?
        pending!("PostgreSQL only")
      end
      Parent.clear
      parent = Parent.create!(name: "x")
      Parent.create!(name: "y")

      found = Parent.where("to_jsonb(name) ?? 'x' AND id = ?", parent.id).to_a
      found.map(&.id).should eq([parent.id])
    end

    it "leaves native placeholder clauses without ?? untouched" do
      clause = "id = ? AND name = 'x?'"
      sqlite.ensure_clause_template(clause).should be(clause)
      mysql.ensure_clause_template(clause).should be(clause)
    end
  end
end
