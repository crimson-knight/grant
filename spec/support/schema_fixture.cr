require "../spec_helper"

# Real tables for the schema introspection specs, created with plain DDL so the
# catalog is read back from a database Grant did not describe itself.
module SchemaFixture
  TABLES = %w(m01_memberships m01_posts m01_authors)

  def self.adapter : Grant::Adapter::Base
    Grant::ConnectionRegistry.get_adapter(CURRENT_ADAPTER)
  end

  def self.exec(sql : String) : Nil
    adapter.open { |db| db.exec sql }
  end

  def self.create! : Nil
    drop!
    id, active, money = case CURRENT_ADAPTER
                        when "pg"
                          {"BIGSERIAL PRIMARY KEY", "BOOLEAN NOT NULL DEFAULT TRUE", "NUMERIC(10,2)"}
                        when "mysql"
                          {"BIGINT AUTO_INCREMENT PRIMARY KEY", "TINYINT(1) NOT NULL DEFAULT 1", "DECIMAL(10,2)"}
                        else
                          {"INTEGER PRIMARY KEY AUTOINCREMENT", "BOOLEAN NOT NULL DEFAULT 1", "NUMERIC(10,2)"}
                        end
    exec <<-SQL
      CREATE TABLE m01_authors (
        id #{id},
        email VARCHAR(120) NOT NULL,
        bio TEXT,
        active #{active},
        created_at TIMESTAMP
      )
      SQL
    exec <<-SQL
      CREATE TABLE m01_posts (
        id #{id},
        author_id BIGINT NOT NULL,
        title VARCHAR(80) NOT NULL,
        score #{money},
        CONSTRAINT fk_m01_posts_author FOREIGN KEY (author_id) REFERENCES m01_authors (id) ON DELETE CASCADE
      )
      SQL
    exec "CREATE UNIQUE INDEX index_m01_posts_on_author_id_and_title ON m01_posts (author_id, title)"
    exec "CREATE INDEX index_m01_posts_on_score ON m01_posts (score)"
    exec "CREATE INDEX index_m01_authors_on_lower_email ON m01_authors ((lower(email)))" unless CURRENT_ADAPTER == "mysql"
    # MySQL refuses SET NULL on a column of the primary key.
    delete_action = CURRENT_ADAPTER == "mysql" ? "RESTRICT" : "SET NULL"
    exec <<-SQL
      CREATE TABLE m01_memberships (
        author_id BIGINT NOT NULL,
        group_id BIGINT NOT NULL,
        role VARCHAR(20),
        PRIMARY KEY (author_id, group_id),
        FOREIGN KEY (author_id) REFERENCES m01_authors (id) ON UPDATE CASCADE ON DELETE #{delete_action}
      )
      SQL
    adapter.reset_schema_caches!
  end

  def self.drop! : Nil
    TABLES.each { |table| exec "DROP TABLE IF EXISTS #{table}" }
    adapter.reset_schema_caches!
  end
end

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  # Models over the fixture tables. The Drifted* ones deliberately disagree with
  # their tables.
  class M01Author < Grant::Base
    connection {{ adapter_literal }}
    table m01_authors

    column id : Int64, primary: true
    column email : String
    column bio : String?
    column active : Bool
    column created_at : Time?
  end

  class M01DriftedAuthor < Grant::Base
    connection {{ adapter_literal }}
    table m01_authors

    column id : Int64, primary: true
    column email : Int32
    column nickname : String?
  end

  class M01PartialAuthor < Grant::Base
    connection {{ adapter_literal }}
    table m01_authors

    column id : Int64, primary: true
    column email : String
    column bio : String
  end

  class M01Ghost < Grant::Base
    connection {{ adapter_literal }}
    table m01_ghosts

    column id : Int64, primary: true
  end

  class M01Membership < Grant::Base
    connection {{ adapter_literal }}
    table m01_memberships

    column author_id : Int64, primary: true
    column group_id : Int64
    column role : String?
  end

  class M01Note < Grant::Base
    connection {{ adapter_literal }}
    table m01_notes

    column id : Int64, primary: true
    column title : String
  end

  # Counts catalog queries so specs can prove the cache spares them.
  class M01CountingAdapter < Grant::Adapter::{{ {"pg" => "Pg", "mysql" => "Mysql", "sqlite" => "Sqlite"}[adapter_literal.stringify].id }}
    getter calls = [] of String

    def catalog_tables(namespace : String? = nil) : Array(String)
      @calls << "tables"
      super
    end

    def catalog_columns(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::ColumnInfo)
      @calls << "columns:#{table}"
      super
    end

    def catalog_indexes(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::IndexInfo)
      @calls << "indexes:#{table}"
      super
    end

    def catalog_foreign_keys(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::ForeignKeyInfo)
      @calls << "foreign_keys:#{table}"
      super
    end
  end
{% end %}
