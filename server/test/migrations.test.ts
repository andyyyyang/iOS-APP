import { fileURLToPath } from "node:url";
import pg from "pg";
import request from "supertest";
import { describe, expect, it } from "vitest";
import { bootstrapStore } from "../src/bootstrap.js";
import { createApp } from "../src/http/app.js";
import { MIGRATIONS, runMigrations } from "../src/store/migrations.js";
import { PostgresStore } from "../src/store/postgres.js";
import { API_KEY, TEST_DATABASE_URL, silentLogger, trackStore } from "./helpers.js";

describe("migrations", () => {
  it("are numbered sequentially from 1", () => {
    expect(MIGRATIONS.map((m) => m.version)).toEqual(MIGRATIONS.map((_, i) => i + 1));
    expect(MIGRATIONS.find((m) => m.version === 2)?.sql).toMatch(/ADD COLUMN IF NOT EXISTS rules TEXT/);
  });

  describe.skipIf(!TEST_DATABASE_URL)("on Postgres", () => {
    it("adds rules to an existing database whose templates have none", async () => {
      const pool = new pg.Pool({ connectionString: TEST_DATABASE_URL });
      try {
        await pool.query("DROP TABLE IF EXISTS scans, templates, write_clock, schema_migrations");
        // A database deployed before rules existed: only migration 1, plus a stored template.
        await runMigrations(pool, MIGRATIONS.filter((m) => m.version === 1), silentLogger);
        await pool.query(
          `INSERT INTO templates (id, name, description, keywords, sample, instructions, version, created_at, updated_at)
           VALUES ('legacy', '舊樣板', '舊的', '{舊}', '{"zeta":1,"alpha":2}', NULL, 3, now(), now())`,
        );

        const store = trackStore(new PostgresStore(TEST_DATABASE_URL!));
        await bootstrapStore(store, { logger: silentLogger, managedTemplatesDir: null });
        const { rows } = await pool.query<{ version: number }>("SELECT version FROM schema_migrations ORDER BY version");
        expect(rows.map((r) => r.version)).toEqual(MIGRATIONS.map((m) => m.version));

        const app = createApp({ store, classifier: null, apiKeys: [API_KEY] });
        const auth = { Authorization: `Bearer ${API_KEY}` };
        const legacy = await request(app).get("/v1/templates/legacy").set(auth).expect(200);
        expect(legacy.body).toMatchObject({ id: "legacy", keywords: ["舊"], rules: [], version: 3 });
        expect(legacy.text).toContain('"sample":{"zeta":1,"alpha":2}');

        const updated = await request(app)
          .put("/v1/templates/legacy")
          .set(auth)
          .send({ name: "舊樣板", description: "舊的", sample: { zeta: 1 }, rules: [{ set: "zeta", value: 2 }] })
          .expect(200);
        expect(updated.body).toMatchObject({ rules: [{ set: "zeta", value: 2 }], version: 4 });

        // Re-running is a no-op.
        await bootstrapStore(store, { logger: silentLogger, managedTemplatesDir: null });
        const { rows: after } = await pool.query("SELECT count(*)::int AS n FROM schema_migrations");
        expect(after[0].n).toBe(MIGRATIONS.length);
      } finally {
        await pool.end();
      }
    });

    it("lets concurrently starting instances seed and sync templates exactly once", async () => {
      const pool = new pg.Pool({ connectionString: TEST_DATABASE_URL });
      await pool.query("DROP TABLE IF EXISTS scans, templates, write_clock, schema_migrations");
      await pool.end();
      const managedTemplatesDir = fileURLToPath(new URL("./fixtures/managed/", import.meta.url));
      const stores = [1, 2, 3].map(() => trackStore(new PostgresStore(TEST_DATABASE_URL!)));
      const results = await Promise.all(
        stores.map((store) => bootstrapStore(store, { logger: silentLogger, managedTemplatesDir })),
      );
      expect(results.flatMap((r) => r.seeded).sort()).toEqual(["business_card", "document", "event", "receipt"]);
      expect(results.flatMap((r) => r.managed!.created).sort()).toEqual(["customs_air", "menu"]);
      expect(results.flatMap((r) => r.managed!.updated)).toEqual([]);
      const templates = await stores[0]!.listTemplates();
      expect(templates.every((t) => t.version === 1)).toBe(true);
    });
  });
});
