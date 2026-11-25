-- Prisma Migrate (sqlite): _prisma_migrations, CreateTable with quoted names and inline FK constraints,
-- implicit many-to-many tables, and the RedefineTables block.
CREATE TABLE "_prisma_migrations" (
    "id"                    TEXT PRIMARY KEY NOT NULL,
    "checksum"              TEXT NOT NULL,
    "finished_at"           DATETIME,
    "migration_name"        TEXT NOT NULL,
    "logs"                  TEXT,
    "rolled_back_at"        DATETIME,
    "started_at"            DATETIME NOT NULL DEFAULT current_timestamp,
    "applied_steps_count"   INTEGER UNSIGNED NOT NULL DEFAULT 0
);
INSERT INTO "_prisma_migrations" ("id", "checksum", "migration_name", "started_at", "applied_steps_count") VALUES ('7b2a', 'c0ffee', '20261125000000_init', '2026-11-25 10:00:00', 0);
-- CreateTable
CREATE TABLE "User" (
    "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    "email" TEXT NOT NULL,
    "name" TEXT,
    "role" TEXT NOT NULL DEFAULT 'USER',
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" DATETIME NOT NULL
);

-- CreateTable
CREATE TABLE "Post" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "title" TEXT NOT NULL,
    "content" TEXT,
    "published" BOOLEAN NOT NULL DEFAULT false,
    "views" BIGINT NOT NULL DEFAULT 0,
    "score" REAL NOT NULL DEFAULT 1.5,
    "price" DECIMAL NOT NULL DEFAULT 0,
    "cover" BLOB,
    "authorId" INTEGER,
    CONSTRAINT "Post_authorId_fkey" FOREIGN KEY ("authorId") REFERENCES "User" ("id") ON DELETE SET NULL ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "Category" (
    "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    "name" TEXT NOT NULL
);

-- CreateTable
CREATE TABLE "_CategoryToPost" (
    "A" INTEGER NOT NULL,
    "B" TEXT NOT NULL,
    CONSTRAINT "_CategoryToPost_A_fkey" FOREIGN KEY ("A") REFERENCES "Category" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT "_CategoryToPost_B_fkey" FOREIGN KEY ("B") REFERENCES "Post" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

-- CreateIndex
CREATE UNIQUE INDEX "User_email_key" ON "User"("email");

-- CreateIndex
CREATE INDEX "Post_authorId_idx" ON "Post"("authorId");

-- CreateIndex
CREATE UNIQUE INDEX "_CategoryToPost_AB_unique" ON "_CategoryToPost"("A", "B");

-- CreateIndex
CREATE INDEX "_CategoryToPost_B_index" ON "_CategoryToPost"("B");
UPDATE "_prisma_migrations" SET "finished_at" = '2026-11-25 10:00:01', "applied_steps_count" = 1 WHERE "id" = '7b2a';
PRAGMA foreign_keys = ON;
INSERT INTO "User" ("email", "name", "updatedAt") VALUES ('alice@prisma.io', 'Alice', '2026-11-25 10:00:00');
INSERT INTO "Post" ("id", "title", "authorId", "cover") VALUES ('p1', 'Hello', 1, x'89504e47');
INSERT INTO "Post" ("id", "title", "authorId", "published", "views") VALUES ('p2', 'World', 1, true, 9007199254740993);
INSERT INTO "Category" ("name") VALUES ('news');
INSERT INTO "_CategoryToPost" ("A", "B") VALUES (1, 'p1'), (1, 'p2');
UPDATE "User" SET "id" = 10 WHERE "id" = 1;
SELECT "authorId" FROM "Post" ORDER BY "id";
DELETE FROM "Category" WHERE "id" = 1;
SELECT count(*) FROM "_CategoryToPost";
-- Migration 2: make Post.title unique, add a required column with a default, drop content
-- RedefineTables
PRAGMA defer_foreign_keys=ON;
PRAGMA foreign_keys=OFF;
CREATE TABLE "new_Post" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "title" TEXT NOT NULL,
    "published" BOOLEAN NOT NULL DEFAULT false,
    "views" BIGINT NOT NULL DEFAULT 0,
    "score" REAL NOT NULL DEFAULT 1.5,
    "price" DECIMAL NOT NULL DEFAULT 0,
    "cover" BLOB,
    "status" TEXT NOT NULL DEFAULT 'DRAFT',
    "authorId" INTEGER,
    CONSTRAINT "Post_authorId_fkey" FOREIGN KEY ("authorId") REFERENCES "User" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);
INSERT INTO "new_Post" ("authorId", "cover", "id", "price", "published", "score", "title", "views") SELECT "authorId", "cover", "id", "price", "published", "score", "title", "views" FROM "Post";
DROP TABLE "Post";
ALTER TABLE "new_Post" RENAME TO "Post";
CREATE INDEX "Post_authorId_idx" ON "Post"("authorId");
CREATE UNIQUE INDEX "Post_title_key" ON "Post"("title");
PRAGMA foreign_keys=ON;
PRAGMA defer_foreign_keys=OFF;
PRAGMA foreign_key_check;
PRAGMA foreign_key_check("Post");
-- Migration 3: AlterTable add column, DropIndex, Rename
ALTER TABLE "User" ADD COLUMN "bio" TEXT;
DROP INDEX "Post_title_key";
ALTER TABLE "Category" RENAME TO "Tag";
SELECT sql FROM sqlite_master WHERE name = '_CategoryToPost';
