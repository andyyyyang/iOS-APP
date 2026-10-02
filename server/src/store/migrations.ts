import type pg from "pg";

export interface Migration {
  version: number;
  name: string;
  sql: string;
}

/**
 * Append-only list. To change the schema, add a new entry with the next version number;
 * never edit a migration that has already shipped.
 */
export const MIGRATIONS: Migration[] = [
  {
    version: 1,
    name: "initial_schema",
    sql: `
      CREATE TABLE IF NOT EXISTS templates (
        id           TEXT COLLATE "C" PRIMARY KEY,
        name         TEXT NOT NULL,
        description  TEXT NOT NULL,
        keywords     TEXT[] NOT NULL DEFAULT '{}',
        sample       TEXT NOT NULL,            -- raw JSON text: preserves key order
        instructions TEXT,
        version      INTEGER NOT NULL DEFAULT 1,
        created_at   TIMESTAMPTZ NOT NULL,
        updated_at   TIMESTAMPTZ NOT NULL
      );

      CREATE TABLE IF NOT EXISTS scans (
        id                 TEXT COLLATE "C" PRIMARY KEY,
        created_at         TIMESTAMPTZ NOT NULL,
        updated_at         TIMESTAMPTZ NOT NULL,
        source             TEXT NOT NULL,
        text               TEXT NOT NULL,
        template_id        TEXT,
        classification     TEXT,                -- raw JSON text
        data               TEXT,                -- raw JSON text
        line_count         INTEGER,
        average_confidence DOUBLE PRECISION,
        page_count         INTEGER,
        device             TEXT
      );

      CREATE INDEX IF NOT EXISTS scans_updated_at_id_idx ON scans (updated_at, id);
      CREATE INDEX IF NOT EXISTS scans_created_at_id_idx ON scans (created_at, id);
      CREATE INDEX IF NOT EXISTS scans_template_id_idx ON scans (template_id);

      -- Single-row clock: every write takes this row lock and gets a strictly larger timestamp,
      -- so updated_at order matches commit order and incremental sync never skips a row.
      CREATE TABLE IF NOT EXISTS write_clock (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        ts TIMESTAMPTZ NOT NULL
      );
      INSERT INTO write_clock (id, ts) VALUES (1, 'epoch') ON CONFLICT (id) DO NOTHING;
    `,
  },
];

// Arbitrary constant key so concurrently starting instances run migrations one at a time.
const MIGRATION_LOCK_KEY = 4_206_942_001;

export async function runMigrations(
  pool: pg.Pool,
  migrations: Migration[] = MIGRATIONS,
  logger: Pick<Console, "info"> = console,
): Promise<void> {
  const client = await pool.connect();
  try {
    await client.query("SELECT pg_advisory_lock($1)", [MIGRATION_LOCK_KEY]);
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version    INTEGER PRIMARY KEY,
        name       TEXT NOT NULL,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
      )
    `);
    const { rows } = await client.query<{ version: number }>("SELECT version FROM schema_migrations");
    const applied = new Set(rows.map((row) => row.version));

    for (const migration of [...migrations].sort((a, b) => a.version - b.version)) {
      if (applied.has(migration.version)) continue;
      await client.query("BEGIN");
      try {
        await client.query(migration.sql);
        await client.query("INSERT INTO schema_migrations (version, name) VALUES ($1, $2)", [
          migration.version,
          migration.name,
        ]);
        await client.query("COMMIT");
        logger.info(`[db] applied migration ${migration.version}_${migration.name}`);
      } catch (error) {
        await client.query("ROLLBACK");
        throw error;
      }
    }
  } finally {
    await client.query("SELECT pg_advisory_unlock($1)", [MIGRATION_LOCK_KEY]).catch(() => {});
    client.release();
  }
}
