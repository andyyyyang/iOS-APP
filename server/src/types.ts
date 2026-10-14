export type JsonValue = string | number | boolean | null | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };

export const SCAN_SOURCES = [
  "photoLibrary",
  "camera",
  "documentScanner",
  "pasteboard",
  "liveScanner",
] as const;
export type ScanSource = (typeof SCAN_SOURCES)[number];

export const CLASSIFICATION_PROVIDERS = ["jev", "on-device", "keywords", "manual"] as const;
export type ClassificationProvider = (typeof CLASSIFICATION_PROVIDERS)[number];

export interface Classification {
  templateId: string;
  confidence?: number | null;
  provider: ClassificationProvider;
  probabilities?: Record<string, number>;
}

/** Wire shape of a scan (API.md "Scan"). Field order here is the JSON output order. */
export interface Scan {
  id: string;
  createdAt: string;
  updatedAt: string;
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

/**
 * Deterministic post-processing step applied by clients after AI extraction.
 * `set` is the target path (`field` or `array[].field`); every other key is free-form JSON
 * (the server stores and returns rules verbatim, key order included, and never applies them).
 */
export type TemplateRule = { set: string } & { [key: string]: JsonValue };

/** Wire shape of a template (API.md "Template"). */
export interface Template {
  id: string;
  name: string;
  description: string;
  keywords: string[];
  sample: JsonObject;
  instructions: string | null;
  rules: TemplateRule[];
  version: number;
  updatedAt: string;
}

export interface ValidationIssue {
  path: string;
  message: string;
}

export interface ValidationResult {
  valid: boolean;
  issues: ValidationIssue[];
}

/** The LocalOCR Sync (Obsidian plugin) release files the server mirrors from GitHub into the vault bucket. */
export const PLUGIN_FILES = ["main.js", "manifest.json"] as const;
export type PluginFileName = (typeof PLUGIN_FILES)[number];

export interface PluginFileInfo {
  /** Lowercase hex SHA-256 of the file's bytes. */
  sha256: string;
  size: number;
}

/**
 * A mirrored LocalOCR Sync release. Kept in the database, not the bucket: every device's Remotely Save
 * holds the bucket keys, so the bucket copies are only served when they still hash to `files`.
 */
export interface PluginRelease {
  /** x.y.z, from the GitHub tag obsidian-plugin-<version> (equal to manifest.json's version). */
  version: string;
  /** manifest.json's minAppVersion ("" when the manifest has none). */
  minAppVersion: string;
  /** The GitHub release body (the CHANGELOG.md section). */
  notes: string;
  publishedAt: string;
  files: Record<PluginFileName, PluginFileInfo>;
  mirroredAt: string;
}
