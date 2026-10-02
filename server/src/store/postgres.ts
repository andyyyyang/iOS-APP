import pg from "pg";
import type { Scan, Template } from "../types.js";
import { STARTUP_LOCK_KEY, runMigrations } from "./migrations.js";
import { rulesToText, scanFromRow, templateFromRow, toJsonText, type ScanRow, type TemplateRow } from "./rows.js";
import type {
  ScanFieldsPatch,
  ScanListOptions,
  ScanWrite,
  Store,
  TemplateWrite,
  WriteResult,
} from "./types.js";

const SCAN_COLUMNS =
  "id, created_at, updated_at, source, text, template_id, classification, data, line_count, average_confidence, page_count, device";
const TEMPLATE_COLUMNS =
  "id, name, description, keywords, sample, instructions, rules, version, created_at, updated_at";

/** Escapes LIKE wildcards so user input is matched literally (used with ESCAPE '\'). */
const likePattern = (q: string) => `%${q.replace(/[\\%_]/g, "\\$&")}%`;

export class PostgresStore implements Store {
  readonly kind = "postgres" as const;
  private readonly pool: pg.Pool;

  constructor(connectionString: string, poolConfig: pg.PoolConfig = {}) {
    this.pool = new pg.Pool({ connectionString, max: 10, ...poolConfig });
    this.pool.on("error", (error) => console.error("[db] idle client error", error));
  }

  async init(): Promise<void> {
    await runMigrations(this.pool);
  }

  async close(): Promise<void> {
    await this.pool.end();
  }

  private async transaction<T>(fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const result = await fn(client);
      await client.query("COMMIT");
      return result;
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  /** Strictly increasing write timestamp (ms precision); the row lock is held until commit. */
  private async tick(client: pg.PoolClient): Promise<Date> {
    const { rows } = await client.query<{ ts: Date }>(
      `UPDATE write_clock
          SET ts = GREATEST(date_trunc('milliseconds', clock_timestamp()), ts + interval '1 millisecond')
        WHERE id = 1
        RETURNING ts`,
    );
    return rows[0]!.ts;
  }

  async getScan(id: string): Promise<Scan | null> {
    const { rows } = await this.pool.query<ScanRow>(`SELECT ${SCAN_COLUMNS} FROM scans WHERE id = $1`, [id]);
    return rows[0] ? scanFromRow(rows[0]) : null;
  }

  async putScan(scan: ScanWrite): Promise<WriteResult<Scan>> {
    return this.transaction(async (client) => {
      const now = await this.tick(client);
      const { rows } = await client.query<ScanRow & { inserted: boolean }>(
        `INSERT INTO scans (${SCAN_COLUMNS})
         VALUES ($1, COALESCE($2::timestamptz, $3), $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
         ON CONFLICT (id) DO UPDATE SET
           updated_at = EXCLUDED.updated_at,
           source = EXCLUDED.source,
           text = EXCLUDED.text,
           template_id = EXCLUDED.template_id,
           classification = EXCLUDED.classification,
           data = EXCLUDED.data,
           line_count = EXCLUDED.line_count,
           average_confidence = EXCLUDED.average_confidence,
           page_count = EXCLUDED.page_count,
           device = EXCLUDED.device
         RETURNING ${SCAN_COLUMNS}, (xmax = 0) AS inserted`,
        [
          scan.id,
          scan.createdAt,
          now,
          scan.source,
          scan.text,
          scan.templateId,
          toJsonText(scan.classification),
          toJsonText(scan.data),
          scan.lineCount,
          scan.averageConfidence,
          scan.pageCount,
          scan.device,
        ],
      );
      const row = rows[0]!;
      return { value: scanFromRow(row), created: row.inserted };
    });
  }

  async patchScan(id: string, patch: ScanFieldsPatch): Promise<Scan | null> {
    return this.transaction(async (client) => {
      const now = await this.tick(client);
      const sets = ["updated_at = $2"];
      const values: unknown[] = [id, now];
      const set = (column: string, value: unknown) => {
        values.push(value);
        sets.push(`${column} = $${values.length}`);
      };
      if (patch.templateId !== undefined) set("template_id", patch.templateId);
      if (patch.data !== undefined) set("data", toJsonText(patch.data));
      if (patch.classification !== undefined) set("classification", toJsonText(patch.classification));

      const { rows } = await client.query<ScanRow>(
        `UPDATE scans SET ${sets.join(", ")} WHERE id = $1 RETURNING ${SCAN_COLUMNS}`,
        values,
      );
      return rows[0] ? scanFromRow(rows[0]) : null;
    });
  }

  async deleteScan(id: string): Promise<boolean> {
    const result = await this.pool.query("DELETE FROM scans WHERE id = $1", [id]);
    return (result.rowCount ?? 0) > 0;
  }

  async listScans(options: ScanListOptions): Promise<Scan[]> {
    const where: string[] = [];
    const values: unknown[] = [];
    const param = (value: unknown) => {
      values.push(value);
      return `$${values.length}`;
    };

    if (options.templateId !== undefined) where.push(`template_id = ${param(options.templateId)}`);
    if (options.q !== undefined) where.push(`text ILIKE ${param(likePattern(options.q))} ESCAPE '\\'`);
    if (options.updatedAfter !== undefined) where.push(`updated_at > ${param(options.updatedAfter)}::timestamptz`);
    const position = options.position;
    if (position?.kind === "updated") {
      where.push(`(updated_at, id) > (${param(position.updatedAt)}::timestamptz, ${param(position.id)})`);
    } else if (position?.kind === "created") {
      where.push(`(created_at, id) < (${param(position.createdAt)}::timestamptz, ${param(position.id)})`);
    }

    const order =
      options.order === "updated_asc" ? "updated_at ASC, id ASC" : "created_at DESC, id DESC";
    const sql = `SELECT ${SCAN_COLUMNS} FROM scans
      ${where.length ? `WHERE ${where.join(" AND ")}` : ""}
      ORDER BY ${order}
      LIMIT ${param(options.limit)}`;

    const { rows } = await this.pool.query<ScanRow>(sql, values);
    return rows.map(scanFromRow);
  }

  async listTemplates(): Promise<Template[]> {
    const { rows } = await this.pool.query<TemplateRow>(
      `SELECT ${TEMPLATE_COLUMNS} FROM templates ORDER BY created_at ASC, id ASC`,
    );
    return rows.map(templateFromRow);
  }

  async getTemplate(id: string): Promise<Template | null> {
    const { rows } = await this.pool.query<TemplateRow>(
      `SELECT ${TEMPLATE_COLUMNS} FROM templates WHERE id = $1`,
      [id],
    );
    return rows[0] ? templateFromRow(rows[0]) : null;
  }

  async putTemplate(template: TemplateWrite): Promise<WriteResult<Template>> {
    return this.transaction(async (client) => {
      const now = await this.tick(client);
      const { rows } = await client.query<TemplateRow & { inserted: boolean }>(
        `INSERT INTO templates (${TEMPLATE_COLUMNS})
         VALUES ($1, $2, $3, $4, $5, $6, $7, 1, $8, $8)
         ON CONFLICT (id) DO UPDATE SET
           name = EXCLUDED.name,
           description = EXCLUDED.description,
           keywords = EXCLUDED.keywords,
           sample = EXCLUDED.sample,
           instructions = EXCLUDED.instructions,
           rules = EXCLUDED.rules,
           version = templates.version + 1,
           updated_at = EXCLUDED.updated_at
         RETURNING ${TEMPLATE_COLUMNS}, (xmax = 0) AS inserted`,
        this.templateParams(template, now),
      );
      const row = rows[0]!;
      return { value: templateFromRow(row), created: row.inserted };
    });
  }

  async insertTemplateIfMissing(template: TemplateWrite): Promise<boolean> {
    return this.transaction(async (client) => {
      const existing = await client.query("SELECT 1 FROM templates WHERE id = $1", [template.id]);
      if (existing.rowCount) return false;
      const now = await this.tick(client);
      const result = await client.query(
        `INSERT INTO templates (${TEMPLATE_COLUMNS})
         VALUES ($1, $2, $3, $4, $5, $6, $7, 1, $8, $8)
         ON CONFLICT (id) DO NOTHING`,
        this.templateParams(template, now),
      );
      return (result.rowCount ?? 0) > 0;
    });
  }

  async deleteTemplate(id: string): Promise<boolean> {
    const result = await this.pool.query("DELETE FROM templates WHERE id = $1", [id]);
    return (result.rowCount ?? 0) > 0;
  }

  async runExclusive<T>(fn: () => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query("SELECT pg_advisory_lock($1)", [STARTUP_LOCK_KEY]);
      return await fn();
    } finally {
      await client.query("SELECT pg_advisory_unlock($1)", [STARTUP_LOCK_KEY]).catch(() => {});
      client.release();
    }
  }

  private templateParams(template: TemplateWrite, now: Date): unknown[] {
    return [
      template.id,
      template.name,
      template.description,
      template.keywords,
      JSON.stringify(template.sample),
      template.instructions,
      rulesToText(template.rules),
      now,
    ];
  }
}
