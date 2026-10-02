import { decodeCursor, encodeCursor, type ScanCursor } from "../cursor.js";
import { invalidRequest, notFound } from "../errors.js";
import { scanIdSchema, scanInputSchema, scanListQuerySchema, scanPatchSchema } from "../schemas.js";
import type { ScanListOptions, Store, WriteResult } from "../store/types.js";
import type { Scan } from "../types.js";
import { parse } from "./parse.js";

export interface ScanPage {
  items: Scan[];
  nextCursor: string | null;
}

export class ScanService {
  constructor(private readonly store: Store) {}

  /** Normalizes a UUID path parameter to canonical uppercase (the iOS app sends uppercase). */
  parseId(rawId: unknown): string {
    return parse(scanIdSchema, rawId, "id: ");
  }

  async get(rawId: unknown): Promise<Scan> {
    const id = this.parseId(rawId);
    const scan = await this.store.getScan(id);
    if (!scan) throw notFound("Scan", id);
    return scan;
  }

  /** Idempotent create-or-replace. The server owns updatedAt; createdAt is kept from the first write. */
  async put(rawId: unknown, body: unknown): Promise<WriteResult<Scan>> {
    const id = this.parseId(rawId);
    const input = parse(scanInputSchema, body);
    if (input.id !== undefined && input.id.toUpperCase() !== id) {
      throw invalidRequest("Body id does not match the URL id");
    }
    return this.store.putScan({
      id,
      createdAt: input.createdAt ?? null,
      source: input.source,
      text: input.text,
      templateId: input.templateId ?? null,
      classification: input.classification ?? null,
      data: input.data ?? null,
      lineCount: input.lineCount ?? null,
      averageConfidence: input.averageConfidence ?? null,
      pageCount: input.pageCount ?? null,
      device: input.device ?? null,
    });
  }

  async patch(rawId: unknown, body: unknown): Promise<Scan> {
    const id = this.parseId(rawId);
    const patch = parse(scanPatchSchema, body);
    const scan = await this.store.patchScan(id, patch);
    if (!scan) throw notFound("Scan", id);
    return scan;
  }

  async delete(rawId: unknown): Promise<void> {
    const id = this.parseId(rawId);
    if (!(await this.store.deleteScan(id))) throw notFound("Scan", id);
  }

  /**
   * With `updatedAfter` or a sync cursor: ascending (updatedAt, id) for incremental sync.
   * Otherwise newest first by createdAt.
   */
  async list(rawQuery: unknown): Promise<ScanPage> {
    const query = parse(scanListQuerySchema, rawQuery);
    const position: ScanCursor | undefined = query.cursor ? decodeCursor(query.cursor) : undefined;
    const order: ScanListOptions["order"] =
      position?.kind === "updated" || (!position && query.updatedAfter) ? "updated_asc" : "created_desc";

    const rows = await this.store.listScans({
      order,
      limit: query.limit + 1,
      templateId: query.templateId,
      q: query.q,
      updatedAfter: query.updatedAfter,
      position,
    });

    const items = rows.slice(0, query.limit);
    const last = items.at(-1);
    const nextCursor =
      rows.length > query.limit && last
        ? encodeCursor(
            order === "updated_asc"
              ? { kind: "updated", updatedAt: last.updatedAt, id: last.id }
              : { kind: "created", createdAt: last.createdAt, id: last.id },
          )
        : null;
    return { items, nextCursor };
  }
}
