import type { Scan, Template } from "../types.js";
import { rulesToText, scanFromRow, templateFromRow, toJsonText, type ScanRow, type TemplateRow } from "./rows.js";
import type {
  ScanFieldsPatch,
  ScanListOptions,
  ScanWrite,
  Store,
  TemplateWrite,
  WriteResult,
} from "./types.js";

/** In-process store for development and tests. Keeps rows in the same TEXT-JSON shape as Postgres. */
export class MemoryStore implements Store {
  readonly kind = "memory" as const;
  private readonly scans = new Map<string, ScanRow>();
  private readonly templates = new Map<string, TemplateRow>();
  private lastWrite = 0;

  async init(): Promise<void> {}
  async close(): Promise<void> {}

  /** Strictly increasing millisecond clock (mirrors the Postgres write_clock). */
  private tick(): Date {
    this.lastWrite = Math.max(Date.now(), this.lastWrite + 1);
    return new Date(this.lastWrite);
  }

  async getScan(id: string): Promise<Scan | null> {
    const row = this.scans.get(id);
    return row ? scanFromRow(row) : null;
  }

  async putScan(scan: ScanWrite): Promise<WriteResult<Scan>> {
    const now = this.tick();
    const existing = this.scans.get(scan.id);
    const row: ScanRow = {
      id: scan.id,
      created_at: existing?.created_at ?? (scan.createdAt ? new Date(scan.createdAt) : now),
      updated_at: now,
      source: scan.source,
      text: scan.text,
      template_id: scan.templateId,
      classification: toJsonText(scan.classification),
      data: toJsonText(scan.data),
      line_count: scan.lineCount,
      average_confidence: scan.averageConfidence,
      page_count: scan.pageCount,
      device: scan.device,
    };
    this.scans.set(scan.id, row);
    return { value: scanFromRow(row), created: !existing };
  }

  async patchScan(id: string, patch: ScanFieldsPatch): Promise<Scan | null> {
    const existing = this.scans.get(id);
    if (!existing) return null;
    const row: ScanRow = { ...existing, updated_at: this.tick() };
    if (patch.templateId !== undefined) row.template_id = patch.templateId;
    if (patch.data !== undefined) row.data = toJsonText(patch.data);
    if (patch.classification !== undefined) row.classification = toJsonText(patch.classification);
    this.scans.set(id, row);
    return scanFromRow(row);
  }

  async deleteScan(id: string): Promise<boolean> {
    return this.scans.delete(id);
  }

  async listScans(options: ScanListOptions): Promise<Scan[]> {
    const needle = options.q?.toLowerCase();
    const updatedAfter = options.updatedAfter ? Date.parse(options.updatedAfter) : undefined;
    const position = options.position;

    const rows = [...this.scans.values()].filter((row) => {
      if (options.templateId !== undefined && row.template_id !== options.templateId) return false;
      if (needle !== undefined && !row.text.toLowerCase().includes(needle)) return false;
      if (updatedAfter !== undefined && row.updated_at.getTime() <= updatedAfter) return false;
      if (position?.kind === "updated") {
        const t = Date.parse(position.updatedAt);
        const u = row.updated_at.getTime();
        if (u < t || (u === t && row.id <= position.id)) return false;
      }
      if (position?.kind === "created") {
        const t = Date.parse(position.createdAt);
        const c = row.created_at.getTime();
        if (c > t || (c === t && row.id >= position.id)) return false;
      }
      return true;
    });

    const byId = (a: ScanRow, b: ScanRow) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
    rows.sort(
      options.order === "updated_asc"
        ? (a, b) => a.updated_at.getTime() - b.updated_at.getTime() || byId(a, b)
        : (a, b) => b.created_at.getTime() - a.created_at.getTime() || byId(b, a),
    );
    return rows.slice(0, options.limit).map(scanFromRow);
  }

  async listTemplates(): Promise<Template[]> {
    return [...this.templates.values()]
      .sort((a, b) => a.created_at.getTime() - b.created_at.getTime() || (a.id < b.id ? -1 : 1))
      .map(templateFromRow);
  }

  async getTemplate(id: string): Promise<Template | null> {
    const row = this.templates.get(id);
    return row ? templateFromRow(row) : null;
  }

  async putTemplate(template: TemplateWrite): Promise<WriteResult<Template>> {
    const now = this.tick();
    const existing = this.templates.get(template.id);
    const row = this.templateRow(template, now, existing);
    this.templates.set(template.id, row);
    return { value: templateFromRow(row), created: !existing };
  }

  async insertTemplateIfMissing(template: TemplateWrite): Promise<boolean> {
    if (this.templates.has(template.id)) return false;
    this.templates.set(template.id, this.templateRow(template, this.tick(), undefined));
    return true;
  }

  async deleteTemplate(id: string): Promise<boolean> {
    return this.templates.delete(id);
  }

  async runExclusive<T>(fn: () => Promise<T>): Promise<T> {
    return fn();
  }

  private templateRow(template: TemplateWrite, now: Date, existing: TemplateRow | undefined): TemplateRow {
    return {
      id: template.id,
      name: template.name,
      description: template.description,
      keywords: [...template.keywords],
      sample: JSON.stringify(template.sample),
      instructions: template.instructions,
      rules: rulesToText(template.rules),
      version: (existing?.version ?? 0) + 1,
      created_at: existing?.created_at ?? now,
      updated_at: now,
    };
  }
}
