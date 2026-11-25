-- Grant's migrator on sqlite, statement for statement: the Grant and Micrate tracking tables,
-- ar_internal_metadata, a migration's DDL, Grant::Schema::TableRebuild's statement list
-- (src/grant/schema/table_rebuild.cr), the schema dumper's catalog queries
-- (src/adapter/sqlite/adapter.cr), and the rollback.
SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations';
CREATE TABLE IF NOT EXISTS schema_migrations (version VARCHAR(255) NOT NULL PRIMARY KEY);
CREATE TABLE IF NOT EXISTS ar_internal_metadata ("key" VARCHAR(255) NOT NULL PRIMARY KEY, value VARCHAR(255), created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP);
INSERT INTO ar_internal_metadata ("key", value) VALUES ('environment', 'development') ON CONFLICT ("key") DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP;
CREATE TABLE micrate_db_version (id INTEGER PRIMARY KEY AUTOINCREMENT, version_id INTEGER NOT NULL, is_applied INTEGER NOT NULL, tstamp TIMESTAMP DEFAULT (datetime('now')));
INSERT INTO micrate_db_version (version_id, is_applied) VALUES (0, 1);
SELECT version FROM "schema_migrations";
BEGIN;
CREATE TABLE "shops" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "name" VARCHAR(255) NOT NULL,
  "slug" VARCHAR(80),
  "rating" NUMERIC(3, 1) DEFAULT 0,
  "created_at" DATETIME NOT NULL,
  "updated_at" DATETIME NOT NULL
);
CREATE UNIQUE INDEX "index_shops_on_slug" ON "shops" ("slug");
CREATE TABLE "products" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "shop_id" BIGINT NOT NULL,
  "title" VARCHAR(255) NOT NULL,
  "price_cents" INTEGER NOT NULL DEFAULT 0,
  "legacy_code" VARCHAR(255),
  CONSTRAINT "fk_products_shop_id" FOREIGN KEY ("shop_id") REFERENCES "shops" ("id") ON DELETE CASCADE,
  CONSTRAINT "chk_products_price" CHECK (price_cents >= 0)
);
CREATE INDEX "index_products_on_shop_id" ON "products" ("shop_id");
CREATE INDEX "index_products_on_legacy_code" ON "products" ("legacy_code");
INSERT INTO "schema_migrations" (version) VALUES ('20261125000001');
INSERT INTO "micrate_db_version" (version_id, is_applied) VALUES (20261125000001, TRUE);
COMMIT;
INSERT INTO shops (name, slug, created_at, updated_at) VALUES ('Corner', 'corner', '2026-11-25 10:00:00', '2026-11-25 10:00:00');
INSERT INTO products (shop_id, title, price_cents, legacy_code) VALUES (1, 'Mug', 1200, 'M-1'), (1, 'Cup', 800, NULL);
-- change_column_null + remove_column :legacy_code through TableRebuild
PRAGMA foreign_keys = OFF;
BEGIN;
CREATE TABLE "__grant_rebuild_products" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "shop_id" BIGINT NOT NULL,
  "title" VARCHAR(255) NOT NULL,
  "price_cents" INTEGER NOT NULL DEFAULT 0,
  "sku" VARCHAR(40) NOT NULL DEFAULT 'none',
  CONSTRAINT "fk_products_shop_id" FOREIGN KEY ("shop_id") REFERENCES "shops" ("id") ON DELETE CASCADE,
  CONSTRAINT "chk_products_price" CHECK (price_cents >= 0)
);
INSERT INTO "__grant_rebuild_products" ("id", "shop_id", "title", "price_cents") SELECT "id", "shop_id", "title", "price_cents" FROM "products";
DROP TABLE "products";
ALTER TABLE "__grant_rebuild_products" RENAME TO "products";
CREATE INDEX "index_products_on_shop_id" ON "products" ("shop_id");
COMMIT;
PRAGMA foreign_keys = ON;
ALTER TABLE "shops" ADD COLUMN "phone" VARCHAR(255);
ALTER TABLE "shops" RENAME COLUMN "rating" TO "stars";
ALTER TABLE "shops" DROP COLUMN "phone";
INSERT INTO "schema_migrations" (version) VALUES ('20261125000002');
SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\_%' ESCAPE '\' ORDER BY name;
SELECT m.name, p.cid, p.name, p.type, p."notnull", p.dflt_value, p.pk FROM sqlite_master m JOIN pragma_table_xinfo(m.name) p WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite\_%' ESCAPE '\' AND p.hidden <> 1 ORDER BY m.name, p.cid;
SELECT m.name, il.name, il."unique", il.partial, ii.name, im.sql FROM sqlite_master m JOIN pragma_index_list(m.name) il JOIN pragma_index_xinfo(il.name) ii ON ii.key = 1 LEFT JOIN sqlite_master im ON im.type = 'index' AND im.name = il.name WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite\_%' ESCAPE '\' AND il.origin <> 'pk' ORDER BY m.name, il.name, ii.seqno;
SELECT m.name, fk.id, fk."table", fk."from", fk."to", fk.on_update, fk.on_delete FROM sqlite_master m JOIN pragma_foreign_key_list(m.name) fk WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite\_%' ESCAPE '\' ORDER BY m.name, fk.id, fk.seq;
SELECT file FROM pragma_database_list WHERE name = 'main' AND file <> '';
DELETE FROM shops WHERE id = 1;
SELECT count(*) FROM products;
-- +micrate Down
DROP TABLE "products";
DROP TABLE "shops";
DELETE FROM "schema_migrations" WHERE version = '20261125000002';
INSERT INTO "micrate_db_version" (version_id, is_applied) VALUES (20261125000001, FALSE);
SELECT version_id, is_applied FROM "micrate_db_version" ORDER BY id DESC;
