-- Rails 7/8 (ActiveRecord sqlite3 adapter): schema bookkeeping, create_table, references, add_index.
CREATE TABLE "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
INSERT INTO "ar_internal_metadata" ("key", "value", "created_at", "updated_at") VALUES ('environment', 'development', '2026-11-25 10:00:00.000000', '2026-11-25 10:00:00.000000') RETURNING "key";
SELECT sqlite_version(*) IS NOT NULL;
BEGIN;
CREATE TABLE "users" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "email" varchar DEFAULT '' NOT NULL, "encrypted_password" varchar DEFAULT '' NOT NULL, "name" varchar, "admin" boolean DEFAULT 0 NOT NULL, "sign_in_count" integer DEFAULT 0 NOT NULL, "balance" decimal(10,2) DEFAULT 0.0, "settings" json DEFAULT '{}' NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_users_on_email" ON "users" ("email");
INSERT INTO "schema_migrations" ("version") VALUES ('20261125000001') RETURNING "version";
COMMIT;
BEGIN;
CREATE TABLE "posts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "user_id" integer NOT NULL, "title" varchar(200) NOT NULL, "body" text, "published" boolean DEFAULT FALSE, "published_at" datetime(6), "lock_version" integer DEFAULT 0 NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_5b5ddfd518"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_posts_on_user_id" ON "posts" ("user_id");
CREATE INDEX "index_posts_on_published_at" ON "posts" ("published_at") WHERE published = 1;
CREATE INDEX "index_posts_on_lower_title" ON "posts" (lower(title));
CREATE INDEX "index_posts_on_user_id_and_created_at" ON "posts" ("user_id", "created_at" DESC);
INSERT INTO "schema_migrations" ("version") VALUES ('20261125000002') RETURNING "version";
COMMIT;
BEGIN;
CREATE TABLE "taggings" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "taggable_type" varchar NOT NULL, "taggable_id" integer NOT NULL, "tag" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE INDEX "index_taggings_on_taggable" ON "taggings" ("taggable_type", "taggable_id");
CREATE UNIQUE INDEX "index_taggings_uniqueness" ON "taggings" ("taggable_type", "taggable_id", "tag");
CREATE TABLE "posts_tags" ("post_id" integer NOT NULL, "tag_id" integer NOT NULL);
CREATE INDEX IF NOT EXISTS "index_posts_tags_on_post_id_and_tag_id" ON "posts_tags" ("post_id", "tag_id");
CREATE INDEX IF NOT EXISTS "index_posts_tags_on_post_id_and_tag_id" ON "posts_tags" ("post_id", "tag_id");
CREATE TABLE "active_storage_blobs" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "key" varchar NOT NULL, "filename" varchar NOT NULL, "content_type" varchar, "metadata" text, "service_name" varchar NOT NULL, "byte_size" bigint NOT NULL, "checksum" varchar, "created_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_active_storage_blobs_on_key" ON "active_storage_blobs" ("key");
INSERT INTO "schema_migrations" ("version") VALUES ('20261125000003') RETURNING "version";
COMMIT;
INSERT INTO "users" ("email", "name", "created_at", "updated_at") VALUES ('a@example.com', 'Ann', '2026-11-25 10:00:00.000000', '2026-11-25 10:00:00.000000') RETURNING "id";
INSERT INTO "users" ("email", "name", "admin", "created_at", "updated_at") VALUES ('b@example.com', 'Bob', 1, '2026-11-25 10:00:00.000000', '2026-11-25 10:00:00.000000') RETURNING "id";
INSERT INTO "posts" ("user_id", "title", "body", "published", "published_at", "created_at", "updated_at") VALUES (1, 'Hello', 'Body', 1, '2026-11-25 11:00:00', '2026-11-25 10:00:00.000000', '2026-11-25 10:00:00.000000');
INSERT INTO "posts" ("user_id", "title", "created_at", "updated_at") VALUES (2, 'Draft', '2026-11-25 10:00:00.000000', '2026-11-25 10:00:00.000000');
INSERT INTO "users" ("email", "created_at", "updated_at") VALUES ('a@example.com', '2026-11-25', '2026-11-25');
INSERT INTO "posts" ("user_id", "created_at", "updated_at") VALUES (1, '2026-11-25', '2026-11-25');
SELECT "schema_migrations"."version" FROM "schema_migrations" ORDER BY "schema_migrations"."version" ASC;
SELECT "ar_internal_metadata"."value" FROM "ar_internal_metadata" WHERE "ar_internal_metadata"."key" = 'environment' ORDER BY "ar_internal_metadata"."key" ASC LIMIT 1;
SELECT name FROM pragma_table_list WHERE schema <> 'temp' AND name NOT IN ('sqlite_sequence', 'sqlite_schema') AND name = 'posts' AND type IN ('table');
SELECT sql FROM (SELECT * FROM sqlite_master UNION ALL SELECT * FROM sqlite_temp_master) WHERE type = 'table' AND name = 'posts';
PRAGMA index_list("posts");
PRAGMA foreign_key_list("posts");
PRAGMA table_xinfo("posts");
-- +micrate Down
BEGIN;
DROP TABLE "taggings";
DROP TABLE "posts_tags";
DELETE FROM "schema_migrations" WHERE "schema_migrations"."version" = '20261125000003';
COMMIT;
