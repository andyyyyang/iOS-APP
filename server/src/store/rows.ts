import type { Classification, JsonObject, JsonValue, Scan, ScanSource, Template } from "../types.js";

// JSON columns are stored as TEXT (not jsonb) so object key order survives the round trip.

export const toJsonText = (value: JsonValue | Classification | null): string | null =>
  value === null ? null : JSON.stringify(value);

export const fromJsonText = <T>(text: string | null): T | null =>
  text === null ? null : (JSON.parse(text) as T);

export interface ScanRow {
  id: string;
  created_at: Date;
  updated_at: Date;
  source: string;
  text: string;
  template_id: string | null;
  classification: string | null;
  data: string | null;
  line_count: number | null;
  average_confidence: number | null;
  page_count: number | null;
  device: string | null;
}

export interface TemplateRow {
  id: string;
  name: string;
  description: string;
  keywords: string[];
  sample: string;
  instructions: string | null;
  version: number;
  created_at: Date;
  updated_at: Date;
}

export function scanFromRow(row: ScanRow): Scan {
  return {
    id: row.id,
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
    source: row.source as ScanSource,
    text: row.text,
    templateId: row.template_id,
    classification: fromJsonText<Classification>(row.classification),
    data: fromJsonText<JsonValue>(row.data),
    lineCount: row.line_count,
    averageConfidence: row.average_confidence,
    pageCount: row.page_count,
    device: row.device,
  };
}

export function templateFromRow(row: TemplateRow): Template {
  return {
    id: row.id,
    name: row.name,
    description: row.description,
    keywords: row.keywords,
    sample: JSON.parse(row.sample) as JsonObject,
    instructions: row.instructions,
    version: row.version,
    updatedAt: row.updated_at.toISOString(),
  };
}
