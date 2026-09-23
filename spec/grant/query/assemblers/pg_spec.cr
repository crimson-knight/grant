require "../spec_helper"

{% if env("CURRENT_ADAPTER").id == "pg" || env("CURRENT_ADAPTER").id == "sqlite" %}
  describe Grant::Query::Assembler::Pg(Model) do
    context "count" do
      it "counts for where/count queries" do
        sql = "select count(*) from table where \"name\" = $1"
        pg_builder.where(name: "bob").assembler.count.raw_sql.should match ignore_whitespace sql
      end

      it "simple counts" do
        sql = "select count(*) from table"
        pg_builder.assembler.count.raw_sql.should match ignore_whitespace sql
      end

      it "adds group_by fields for where/count queries" do
        sql = "select count(*) from table where \"name\" = $1 group by name"
        pg_builder.where(name: "bob").group_by(:name).assembler.count.raw_sql.should match ignore_whitespace sql
      end
    end

    context "group_by" do
      it "adds group_by for select query" do
        sql = "select #{query_fields} from table group by name"
        pg_builder.group_by(:name).raw_sql.should match ignore_whitespace sql
      end

      it "adds multiple group_by for select query" do
        sql = "select #{query_fields} from table group by name, age"
        pg_builder.group_by([:name, :age]).raw_sql.should match ignore_whitespace sql
      end

      it "adds chain of group_by for select query" do
        sql = "select #{query_fields} from table group by id, name, age order by id desc"
        pg_builder.group_by(:id).group_by([:name, :age]).raw_sql.should match ignore_whitespace sql
      end
    end

    context "where" do
      it "properly numbers fields" do
        sql = "select #{query_fields} from table where \"name\" = $1 and \"age\" = $2 order by id desc"
        query = pg_builder.where(name: "bob", age: "23")
        query.raw_sql.should match ignore_whitespace sql

        assembler = query.assembler
        assembler.where
        assembler.numbered_parameters.should eq ["bob", "23"]
      end

      it "property defines IN query" do
        sql = "SELECT #{query_fields} FROM table WHERE \"date_completed\" IS NULL AND \"status\" IN ($1,$2) ORDER BY id DESC"
        query = pg_builder.where(date_completed: nil, status: ["outstanding", "in_progress"])
        query.raw_sql.should match ignore_whitespace sql

        assembler = query.assembler
        assembler.where
        assembler.numbered_parameters.should eq ["outstanding", "in_progress"]
      end

      it "property defines IN query with numbers" do
        sql = "SELECT #{query_fields} FROM table WHERE \"date_completed\" IS NULL AND \"id\" IN ($1,$2) ORDER BY id DESC"
        query = pg_builder.where(date_completed: nil, id: [1, 2])
        query.raw_sql.should match ignore_whitespace sql

        assembler = query.assembler
        assembler.where
        assembler.numbered_parameters.should eq [1, 2]
      end

      it "property defines IN query with booleans" do
        sql = "SELECT #{query_fields} FROM table WHERE \"published\" IN ($1,$2) ORDER BY id DESC"
        query = pg_builder.where(published: [true, false])
        query.raw_sql.should match ignore_whitespace sql

        assembler = query.assembler
        assembler.where
        assembler.numbered_parameters.should eq [true, false]
      end

      it "handles raw SQL with ? placeholders" do
        sql = "select #{query_fields} from table where name = 'bob' and age = $1 and color = $2 order by id desc"
        query = pg_builder.where("name = 'bob'").where("age = ?", 23).where("color = ?", "red")
        query.raw_sql.should match ignore_whitespace sql

        assembler = query.assembler
        assembler.where
        assembler.numbered_parameters.should eq [23, "red"]
      end

      it "converts ? to $N in raw SQL for PG compatibility" do
        # This is the core fix: querying.cr passes "id = ?" through
        # query.where(), and the PG assembler must convert ? to $1
        sql = "select #{query_fields} from table where id = $1 order by id desc"
        query = pg_builder.where("id = ?", 42)
        query.raw_sql.should match ignore_whitespace sql

        assembler = query.assembler
        assembler.where
        assembler.numbered_parameters.should eq [42]
      end
    end

    context "order" do
      it "uses default sort when no sort is provided" do
        pg_builder.raw_sql.should match ignore_whitespace "select #{query_fields} from table order by id desc"
      end

      it "uses specified sort when provided" do
        sql = "select #{query_fields} from table order by id asc"
        pg_builder.order(id: :asc).raw_sql.should match ignore_whitespace sql
      end
    end

    context "offset" do
      it "adds offset for select query" do
        sql = "select #{query_fields} from table order by id desc offset 8"
        pg_builder.offset(8).raw_sql.should match ignore_whitespace sql
      end

      it "adds offset for first query" do
        sql = "select #{query_fields} from table order by id desc limit 1 offset 3"
        pg_builder.offset(3).assembler.first.raw_sql.should match ignore_whitespace sql
      end
    end

    context "limit" do
      it "adds limit for select query" do
        sql = "select #{query_fields} from table order by id desc limit 5"
        pg_builder.limit(5).raw_sql.should match ignore_whitespace sql
      end
    end
  end
{% end %}
