-- Rails 7/8: add_column, rename_column, remove_column, change_column through
-- the adapter's alter_table (copy through a TEMPORARY table inside a transaction
-- with referential integrity disabled), and add_reference with a foreign key.
PRAGMA foreign_keys = ON;
CREATE TABLE "authors" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE TABLE "books" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "author_id" integer NOT NULL, "title" varchar, "pages" integer, "price" float, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_53d51ce16a"
FOREIGN KEY ("author_id")
  REFERENCES "authors" ("id")
 ON DELETE CASCADE);
CREATE INDEX "index_books_on_author_id" ON "books" ("author_id");
CREATE INDEX "index_books_on_title" ON "books" ("title");
INSERT INTO "authors" ("name", "created_at", "updated_at") VALUES ('Le Guin', '2026-01-01', '2026-01-01'), ('Banks', '2026-01-02', '2026-01-02');
INSERT INTO "books" ("author_id", "title", "pages", "price", "created_at", "updated_at") VALUES (1, 'Lathe', 184, 9.5, '2026-01-01', '2026-01-01'), (1, 'Dispossessed', 387, 12.25, '2026-01-01', '2026-01-01'), (2, 'Player', 309, NULL, '2026-01-02', '2026-01-02');
ALTER TABLE "books" ADD "isbn" varchar;
ALTER TABLE "books" ADD "status" varchar DEFAULT 'draft' NOT NULL;
ALTER TABLE "books" ADD "ratings_count" integer DEFAULT 0 NOT NULL;
ALTER TABLE "books" ADD "slug" varchar GENERATED ALWAYS AS (lower(replace(title, ' ', '-'))) VIRTUAL;
CREATE UNIQUE INDEX "index_books_on_isbn" ON "books" ("isbn");
ALTER TABLE "books" RENAME COLUMN "pages" TO "page_count";
ALTER TABLE "books" RENAME COLUMN "title" TO "name";
-- change_column :books, :price, :decimal, precision: 8, scale: 2, null: false, default: 0
PRAGMA foreign_keys;
PRAGMA defer_foreign_keys;
BEGIN;
PRAGMA defer_foreign_keys = ON;
PRAGMA foreign_keys = OFF;
CREATE TEMPORARY TABLE "abooks" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "author_id" integer NOT NULL, "name" varchar DEFAULT NULL, "page_count" integer DEFAULT NULL, "price" decimal(8,2) DEFAULT 0 NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "isbn" varchar DEFAULT NULL, "status" varchar DEFAULT 'draft' NOT NULL, "ratings_count" integer DEFAULT 0 NOT NULL);
CREATE INDEX "tindex_books_on_author_id" ON "abooks" ("author_id");
CREATE INDEX "tindex_books_on_title" ON "abooks" ("name");
CREATE UNIQUE INDEX "tindex_books_on_isbn" ON "abooks" ("isbn");
INSERT INTO "abooks" ("id","author_id","name","page_count","price","created_at","updated_at","isbn","status","ratings_count")
                     SELECT "id","author_id","name","page_count",IFNULL("price", 0),"created_at","updated_at","isbn","status","ratings_count" FROM "books";
DROP TABLE "books";
CREATE TABLE "books" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "author_id" integer NOT NULL, "name" varchar DEFAULT NULL, "page_count" integer DEFAULT NULL, "price" decimal(8,2) DEFAULT 0 NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "isbn" varchar DEFAULT NULL, "status" varchar DEFAULT 'draft' NOT NULL, "ratings_count" integer DEFAULT 0 NOT NULL, CONSTRAINT "fk_rails_53d51ce16a"
FOREIGN KEY ("author_id")
  REFERENCES "authors" ("id")
 ON DELETE CASCADE);
CREATE INDEX "index_books_on_author_id" ON "books" ("author_id");
CREATE INDEX "index_books_on_title" ON "books" ("name");
CREATE UNIQUE INDEX "index_books_on_isbn" ON "books" ("isbn");
INSERT INTO "books" ("id","author_id","name","page_count","price","created_at","updated_at","isbn","status","ratings_count")
                     SELECT "id","author_id","name","page_count","price","created_at","updated_at","isbn","status","ratings_count" FROM "abooks";
DROP TABLE "abooks";
PRAGMA foreign_key_check;
PRAGMA defer_foreign_keys = 0;
PRAGMA foreign_keys = 1;
COMMIT;
-- remove_column (native DROP COLUMN since Rails 7.1 on SQLite >= 3.35)
ALTER TABLE "books" DROP COLUMN "ratings_count";
ALTER TABLE "books" DROP COLUMN "isbn";
DROP INDEX "index_books_on_isbn";
ALTER TABLE "books" DROP COLUMN "isbn";
ALTER TABLE "books" DROP COLUMN "author_id";
-- add_reference :books, :publisher, foreign_key: true (column without the constraint, then index)
CREATE TABLE "publishers" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar);
ALTER TABLE "books" ADD "publisher_id" integer REFERENCES "publishers" ("id");
ALTER TABLE "books" ADD "editor_id" integer NOT NULL REFERENCES "users" ("id");
ALTER TABLE "books" ADD "editor_id" integer DEFAULT 1 NOT NULL;
CREATE INDEX "index_books_on_publisher_id" ON "books" ("publisher_id");
ALTER TABLE "books" RENAME TO "volumes";
ALTER TABLE "authors" RENAME TO "writers";
DELETE FROM "writers" WHERE "id" = 1;
SELECT count(*) FROM "volumes";
PRAGMA foreign_key_list("volumes");
