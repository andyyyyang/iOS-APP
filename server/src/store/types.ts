import type { ScanCursor } from "../cursor.js";
import type { Classification, JsonObject, JsonValue, Scan, ScanSource, Template } from "../types.js";

export interface ScanWrite {
  id: string;
  /** Used only when the scan is created; an existing scan keeps its original createdAt. */
  createdAt: string | null;
  source: ScanSource;
  text: string;
  templateId: string | null;
  classification: Classification | null;
  data: JsonValue | null;
  lineCount: number | null;
  averageConfidence: number | null;
  pageCount: number | null;
  device: string | null;
}

/** Only the provided (non-undefined) fields are changed; `null` clears. */
export interface ScanFieldsPatch {
  templateId?: string | null;
  data?: JsonValue | null;
  classification?: Classification | null;
}

export type ScanOrder = "updated_asc" | "created_desc";

export interface ScanListOptions {
  order: ScanOrder;
  limit: number;
  templateId?: string;
  /** Case-insensitive substring match on the OCR text. */
  q?: string;
  /** Only rows with updatedAt strictly greater than this. */
  updatedAfter?: string;
  /** Keyset position; its kind must match `order`. */
  position?: ScanCursor;
}

export interface TemplateWrite {
  id: string;
  name: string;
  description: string;
  keywords: string[];
  sample: JsonObject;
  instructions: string | null;
}

export interface WriteResult<T> {
  value: T;
  created: boolean;
}

/**
 * Persistence boundary. Implementations set `updatedAt` on every write from a clock that is
 * strictly increasing per store, so incremental sync by (updatedAt, id) never misses a write.
 */
export interface Store {
  readonly kind: "postgres" | "memory";
  init(): Promise<void>;
  close(): Promise<void>;

  getScan(id: string): Promise<Scan | null>;
  putScan(scan: ScanWrite): Promise<WriteResult<Scan>>;
  patchScan(id: string, patch: ScanFieldsPatch): Promise<Scan | null>;
  deleteScan(id: string): Promise<boolean>;
  listScans(options: ScanListOptions): Promise<Scan[]>;

  listTemplates(): Promise<Template[]>;
  getTemplate(id: string): Promise<Template | null>;
  /** Creates (version 1) or replaces (version + 1). */
  putTemplate(template: TemplateWrite): Promise<WriteResult<Template>>;
  /** Inserts only if no template with this id exists. Returns true if inserted. */
  insertTemplateIfMissing(template: TemplateWrite): Promise<boolean>;
  deleteTemplate(id: string): Promise<boolean>;
}
