import type {
  Classification,
  JsonObject,
  JsonValue,
  PluginFileInfo,
  PluginFileName,
  PluginRelease,
  Scan,
  ScanSource,
  Template,
  TemplateRule,
} from "../types.js";

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
  /** Raw JSON array text; NULL for rows written before migration 2. */
  rules: string | null;
  version: number;
  created_at: Date;
  updated_at: Date;
}

/** Empty rule lists are stored as NULL so "no rules" has a single representation. */
export const rulesToText = (rules: TemplateRule[]): string | null =>
  rules.length === 0 ? null : JSON.stringify(rules);

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
    rules: row.rules === null ? [] : (JSON.parse(row.rules) as TemplateRule[]),
    version: row.version,
    updatedAt: row.updated_at.toISOString(),
  };
}

export interface PluginReleaseRow {
  version: string;
  min_app_version: string;
  notes: string;
  published_at: Date;
  /** Raw JSON text: {"main.js":{"sha256","size"},"manifest.json":{"sha256","size"}}. */
  files: string;
  mirrored_at: Date;
}

export function pluginReleaseToRow(release: PluginRelease): PluginReleaseRow {
  return {
    version: release.version,
    min_app_version: release.minAppVersion,
    notes: release.notes,
    published_at: new Date(release.publishedAt),
    files: JSON.stringify(release.files),
    mirrored_at: new Date(release.mirroredAt),
  };
}

export function pluginReleaseFromRow(row: PluginReleaseRow): PluginRelease {
  return {
    version: row.version,
    minAppVersion: row.min_app_version,
    notes: row.notes,
    publishedAt: row.published_at.toISOString(),
    files: JSON.parse(row.files) as Record<PluginFileName, PluginFileInfo>,
    mirroredAt: row.mirrored_at.toISOString(),
  };
}
