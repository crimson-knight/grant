require "../../spec_helper"

# Shared STI model hierarchy used by the STI specs.
#
# `Persona` is the STI root (it does `include Grant::STI` and declares the
# `type` column). `AdminPersona` / `MemberPersona` are subclasses that add
# their own type-specific columns and permission behaviour — the exact shape
# of Seth's type-safe personas/permissions use case.
{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class Persona < Grant::Base
    include Grant::STI
    connection {{ adapter_literal }}
    table sti_personas

    column id : Int64, primary: true
    column type : String
    column name : String
    column role : String?

    # Shared base behaviour: every persona has at least read permission.
    def permissions : Array(String)
      ["read"]
    end
  end

  class AdminPersona < Persona
    column access_level : Int32?

    def permissions : Array(String)
      ["read", "write", "admin"]
    end
  end

  class MemberPersona < Persona
    column membership_tier : String?
    column active : Bool?

    def permissions : Array(String)
      (active ? ["read", "comment"] : ["read"])
    end
  end

  # A deeper level to exercise multi-level inheritance (Car < Vehicle < Base).
  class SuperAdminPersona < AdminPersona
    column god_mode : Bool?

    def permissions : Array(String)
      ["read", "write", "admin", "superadmin"]
    end
  end

  # A separate hierarchy with a CUSTOM inheritance column name.
  class Document < Grant::Base
    include Grant::STI
    connection {{ adapter_literal }}
    table sti_documents

    # Use `doc_type` instead of the default `type` column.
    def self.inheritance_column : String
      "doc_type"
    end

    column id : Int64, primary: true
    column doc_type : String
    column title : String
  end

  class Contract < Document
    column counterparty : String?
  end

  class Report < Document
    column summary : String?
  end
{% end %}

# Create the shared STI tables once, with the full union of every subclass's
# columns (a single STI migration, exactly as the STI guide recommends). We use
# raw DDL because Grant's per-class migrator would only know one class's view of
# the shared table.
def setup_sti_tables
  Persona.adapter.open do |db|
    db.exec "DROP TABLE IF EXISTS sti_personas"
    if CURRENT_ADAPTER == "pg"
      db.exec <<-SQL
        CREATE TABLE sti_personas (
          id BIGSERIAL PRIMARY KEY,
          type TEXT NOT NULL,
          name TEXT NOT NULL,
          role TEXT,
          access_level INTEGER,
          membership_tier TEXT,
          active BOOLEAN,
          god_mode BOOLEAN
        )
        SQL
    elsif CURRENT_ADAPTER == "mysql"
      db.exec <<-SQL
        CREATE TABLE sti_personas (
          id BIGINT AUTO_INCREMENT PRIMARY KEY,
          type VARCHAR(255) NOT NULL,
          name VARCHAR(255) NOT NULL,
          role VARCHAR(255),
          access_level INTEGER,
          membership_tier VARCHAR(255),
          active BOOLEAN,
          god_mode BOOLEAN
        )
        SQL
    else
      db.exec <<-SQL
        CREATE TABLE sti_personas (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          type VARCHAR(255) NOT NULL,
          name VARCHAR(255) NOT NULL,
          role VARCHAR(255),
          access_level INTEGER,
          membership_tier VARCHAR(255),
          active BOOLEAN,
          god_mode BOOLEAN
        )
        SQL
    end
  end

  Document.adapter.open do |db|
    db.exec "DROP TABLE IF EXISTS sti_documents"
    if CURRENT_ADAPTER == "pg"
      db.exec <<-SQL
        CREATE TABLE sti_documents (
          id BIGSERIAL PRIMARY KEY,
          doc_type TEXT NOT NULL,
          title TEXT NOT NULL,
          counterparty TEXT,
          summary TEXT
        )
        SQL
    elsif CURRENT_ADAPTER == "mysql"
      db.exec <<-SQL
        CREATE TABLE sti_documents (
          id BIGINT AUTO_INCREMENT PRIMARY KEY,
          doc_type VARCHAR(255) NOT NULL,
          title VARCHAR(255) NOT NULL,
          counterparty VARCHAR(255),
          summary VARCHAR(255)
        )
        SQL
    else
      db.exec <<-SQL
        CREATE TABLE sti_documents (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          doc_type VARCHAR(255) NOT NULL,
          title VARCHAR(255) NOT NULL,
          counterparty VARCHAR(255),
          summary VARCHAR(255)
        )
        SQL
    end
  end
end

def clear_sti_tables
  Persona.adapter.open(&.exec("DELETE FROM sti_personas"))
  Document.adapter.open(&.exec("DELETE FROM sti_documents"))
end
