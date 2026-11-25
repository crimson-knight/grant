-- Django 5 (sqlite3 schema editor): django_migrations, auth tables, FK DEFERRABLE INITIALLY DEFERRED,
-- CHECK constraints for positive and JSON fields, and the "new__" table rebuild.
CREATE TABLE "django_migrations" ("id" integer NOT NULL PRIMARY KEY AUTOINCREMENT, "app" varchar(255) NOT NULL, "name" varchar(255) NOT NULL, "applied" datetime NOT NULL);
PRAGMA foreign_keys;
PRAGMA foreign_keys = OFF;
PRAGMA foreign_keys;
BEGIN;
CREATE TABLE "django_content_type" ("id" integer NOT NULL PRIMARY KEY AUTOINCREMENT, "app_label" varchar(100) NOT NULL, "model" varchar(100) NOT NULL);
CREATE UNIQUE INDEX "django_content_type_app_label_model_76bd3d3b_uniq" ON "django_content_type" ("app_label", "model");
CREATE TABLE "auth_user" ("id" integer NOT NULL PRIMARY KEY AUTOINCREMENT, "password" varchar(128) NOT NULL, "last_login" datetime NULL, "is_superuser" bool NOT NULL, "username" varchar(150) NOT NULL UNIQUE, "first_name" varchar(150) NOT NULL, "last_name" varchar(150) NOT NULL, "email" varchar(254) NOT NULL, "is_staff" bool NOT NULL, "is_active" bool NOT NULL, "date_joined" datetime NOT NULL);
CREATE TABLE "auth_group" ("id" integer NOT NULL PRIMARY KEY AUTOINCREMENT, "name" varchar(150) NOT NULL UNIQUE);
CREATE TABLE "auth_user_groups" ("id" integer NOT NULL PRIMARY KEY AUTOINCREMENT, "user_id" integer NOT NULL REFERENCES "auth_user" ("id") DEFERRABLE INITIALLY DEFERRED, "group_id" integer NOT NULL REFERENCES "auth_group" ("id") DEFERRABLE INITIALLY DEFERRED);
CREATE UNIQUE INDEX "auth_user_groups_user_id_group_id_94350c0c_uniq" ON "auth_user_groups" ("user_id", "group_id");
CREATE INDEX "auth_user_groups_user_id_6a12ed8b" ON "auth_user_groups" ("user_id");
CREATE INDEX "auth_user_groups_group_id_97559544" ON "auth_user_groups" ("group_id");
CREATE TABLE "blog_entry" ("id" integer NOT NULL PRIMARY KEY AUTOINCREMENT, "headline" varchar(255) NOT NULL, "body_text" text NOT NULL, "pub_date" date NOT NULL, "rating" integer unsigned NOT NULL CHECK ("rating" >= 0), "data" text NOT NULL CHECK ((JSON_VALID("data") OR "data" IS NULL)), "uuid" char(32) NOT NULL UNIQUE, "price" decimal NOT NULL, "author_id" integer NOT NULL REFERENCES "auth_user" ("id") DEFERRABLE INITIALLY DEFERRED);
CREATE INDEX "blog_entry_author_id_7d6e8a7f" ON "blog_entry" ("author_id");
INSERT INTO "django_migrations" ("app", "name", "applied") VALUES ('blog', '0001_initial', '2026-11-25 10:00:00.000000');
COMMIT;
PRAGMA foreign_key_check;
PRAGMA foreign_keys = ON;
INSERT INTO "auth_user" ("password", "last_login", "is_superuser", "username", "first_name", "last_name", "email", "is_staff", "is_active", "date_joined") VALUES ('pbkdf2', NULL, 1, 'admin', '', '', 'a@example.com', 1, 1, '2026-11-25 10:00:00');
INSERT INTO "blog_entry" ("headline", "body_text", "pub_date", "rating", "data", "uuid", "price", "author_id") VALUES ('First', 'text', '2026-11-25', 5, '{"a": 1}', 'a1b2c3', '10.50', 1);
INSERT INTO "blog_entry" ("headline", "body_text", "pub_date", "rating", "data", "uuid", "price", "author_id") VALUES ('Bad', 'text', '2026-11-25', -1, '{}', 'x1', '1', 1);
INSERT INTO "blog_entry" ("headline", "body_text", "pub_date", "rating", "data", "uuid", "price", "author_id") VALUES ('Bad', 'text', '2026-11-25', 1, 'not json', 'x2', '1', 1);
BEGIN;
INSERT INTO "blog_entry" ("headline", "body_text", "pub_date", "rating", "data", "uuid", "price", "author_id") VALUES ('Orphan', 'text', '2026-11-25', 1, '{}', 'x3', '1', 99);
COMMIT;
-- 0002: AddField with a default, AlterField (table rebuild), RenameField, AddConstraint, AddIndex
PRAGMA foreign_keys = OFF;
BEGIN;
ALTER TABLE "blog_entry" ADD COLUMN "slug" varchar(50) NULL;
CREATE INDEX "blog_entry_slug_2b2b5f4e" ON "blog_entry" ("slug");
ALTER TABLE "blog_entry" ADD COLUMN "views" integer unsigned DEFAULT 0 NOT NULL CHECK ("views" >= 0);
CREATE TABLE "new__blog_entry" ("id" integer NOT NULL PRIMARY KEY AUTOINCREMENT, "headline" varchar(300) NOT NULL, "body_text" text NOT NULL, "pub_date" date NOT NULL, "rating" integer unsigned NOT NULL CHECK ("rating" >= 0), "data" text NOT NULL CHECK ((JSON_VALID("data") OR "data" IS NULL)), "uuid" char(32) NOT NULL UNIQUE, "price" decimal NOT NULL, "author_id" integer NOT NULL REFERENCES "auth_user" ("id") DEFERRABLE INITIALLY DEFERRED, "slug" varchar(50) NULL, "views" integer unsigned NOT NULL CHECK ("views" >= 0), CONSTRAINT "headline_not_empty" CHECK (NOT ("headline" = '')));
INSERT INTO "new__blog_entry" ("id", "headline", "body_text", "pub_date", "rating", "data", "uuid", "price", "author_id", "slug", "views") SELECT "id", "headline", "body_text", "pub_date", "rating", "data", "uuid", "price", "author_id", "slug", "views" FROM "blog_entry";
DROP TABLE "blog_entry";
ALTER TABLE "new__blog_entry" RENAME TO "blog_entry";
CREATE INDEX "blog_entry_author_id_7d6e8a7f" ON "blog_entry" ("author_id");
CREATE INDEX "blog_entry_slug_2b2b5f4e" ON "blog_entry" ("slug");
ALTER TABLE "blog_entry" RENAME COLUMN "body_text" TO "body";
CREATE INDEX "blog_entry_pub_date_idx" ON "blog_entry" ("pub_date" DESC, "headline");
CREATE UNIQUE INDEX "unique_slug_per_author" ON "blog_entry" ("author_id", "slug") WHERE "slug" IS NOT NULL;
INSERT INTO "django_migrations" ("app", "name", "applied") VALUES ('blog', '0002_entry_slug', '2026-11-25 10:00:01.000000');
COMMIT;
PRAGMA foreign_key_check;
PRAGMA foreign_keys = ON;
-- data migration (RunPython / RunSQL)
UPDATE "blog_entry" SET "slug" = lower(replace("headline", ' ', '-')) WHERE "slug" IS NULL;
INSERT INTO "blog_entry" ("headline", "body", "pub_date", "rating", "data", "uuid", "price", "author_id", "slug", "views") VALUES ('First', 't', '2026-11-26', 1, '{}', 'x9', '1', 1, 'first', 0);
INSERT INTO "blog_entry" ("headline", "body", "pub_date", "rating", "data", "uuid", "price", "author_id", "slug", "views") VALUES ('', 't', '2026-11-26', 1, '{}', 'x8', '1', 1, NULL, 0);
-- RemoveField and DeleteModel
ALTER TABLE "blog_entry" DROP COLUMN "views";
DROP TABLE "auth_user_groups";
SELECT "django_migrations"."id", "django_migrations"."app", "django_migrations"."name", "django_migrations"."applied" FROM "django_migrations" ORDER BY "django_migrations"."id";
