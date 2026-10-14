import { AppError } from "../errors.js";
import type { Scan } from "../types.js";
import type { VaultService } from "./vault.js";

// Scans → JSON record arrays in the vault (the same "JSON 陣列輸出" the Obsidian plugin does, now on the server so a
// scan shows up in its record file — e.g. the FV60 dataviewjs tool's `11 SOP/fv60-廠商請款-紀錄.json` — the moment
// the app uploads it, with or without Obsidian running). Records are matched by `id` only: a new scan is inserted
// first (newest first); a re-uploaded scan replaces its record but keeps the fields filled in later (SAP docNo,
// done); a record marked done is never touched. The plugin's own export of the same scan is a no-op afterwards.

export interface RecordOutput {
  templateId: string;
  /** Vault path of the JSON array file. */
  path: string;
  /** Fields whose existing values survive an update. */
  preserve: string[];
  /** A truthy value here means finished: the record is left alone. Empty = none. */
  doneField: string;
  /** Create the file when it is missing (default false: only add to files the vault already has). */
  create: boolean;
}

export type RecordOutcome = "created" | "updated" | "skipped" | "unchanged" | "no-file" | "invalid-file" | "no-data";

/** FV60 vendor billing: both scenarios feed the record file the FV60 dataviewjs note reads and edits. */
export const DEFAULT_RECORD_OUTPUTS: RecordOutput[] = [
  { templateId: "fv60_air", path: "11 SOP/fv60-廠商請款-紀錄.json", preserve: ["docNo", "done"], doneField: "done", create: false },
  { templateId: "fv60_sea", path: "11 SOP/fv60-廠商請款-紀錄.json", preserve: ["docNo", "done"], doneField: "done", create: false },
];

/**
 * SCAN_RECORD_OUTPUTS: "off" disables the export; otherwise "templateId=path; templateId=path" replaces the defaults
 * (those files are created when missing). Unset = the FV60 defaults (only into files that already exist).
 */
export function parseRecordOutputs(value: string | undefined): RecordOutput[] {
  if (value === undefined || value.trim() === "") return DEFAULT_RECORD_OUTPUTS;
  if (/^(off|none|false|0)$/i.test(value.trim())) return [];
  return value
    .split(/[;\n]/)
    .map((part) => part.trim())
    .filter(Boolean)
    .flatMap((part): RecordOutput[] => {
      const eq = part.indexOf("=");
      if (eq <= 0) return [];
      const templateId = part.slice(0, eq).trim();
      const path = part.slice(eq + 1).trim().replace(/^\/+/, "");
      if (!templateId || !path) return [];
      return [{ templateId, path, preserve: ["docNo", "done"], doneField: "done", create: true }];
    });
}

type JsonRecord = Record<string, unknown>;

const isRecord = (value: unknown): value is JsonRecord => typeof value === "object" && value !== null && !Array.isArray(value);

export function recordIdOf(item: unknown): string | null {
  if (!isRecord(item)) return null;
  const id = item.id;
  if (typeof id === "string" && id.trim()) return id;
  if (typeof id === "number" && Number.isFinite(id)) return String(id);
  return null;
}

/** The record for a scan: its data as received; without a usable id the scan id is used (first key, or in place). */
export function recordFor(scan: Pick<Scan, "id" | "data">): { record: JsonRecord; id: string } | null {
  if (!isRecord(scan.data)) return null;
  const existing = recordIdOf(scan.data);
  if (existing !== null) return { record: { ...scan.data }, id: existing };
  const record = "id" in scan.data ? { ...scan.data, id: scan.id } : { id: scan.id, ...scan.data };
  return { record, id: scan.id };
}

/** Insert or update a record in an array (not mutated); matched by id, then by the alternative ids. */
export function upsertRecord(
  array: readonly unknown[],
  incoming: { record: JsonRecord; id: string },
  output: Pick<RecordOutput, "preserve" | "doneField">,
  altIds: readonly string[] = [],
): { array: unknown[]; outcome: "created" | "updated" | "skipped" | "unchanged" } {
  let index = -1;
  for (const id of [incoming.id, ...altIds]) {
    index = array.findIndex((item) => recordIdOf(item) === id);
    if (index >= 0) break;
  }
  if (index < 0) return { array: [incoming.record, ...array], outcome: "created" };
  const existing = array[index] as JsonRecord;
  if (output.doneField && existing[output.doneField]) return { array: [...array], outcome: "skipped" };
  const merged: JsonRecord = { ...incoming.record };
  for (const field of output.preserve) {
    if (Object.prototype.hasOwnProperty.call(existing, field)) merged[field] = existing[field];
  }
  if (JSON.stringify(merged) === JSON.stringify(existing)) return { array: [...array], outcome: "unchanged" };
  const next = [...array];
  next[index] = merged;
  return { array: next, outcome: "updated" };
}

/** Writes scans into their record files; failures are logged and never fail the scan upload. */
export class ScanRecordExporter {
  constructor(
    private readonly vault: VaultService,
    private readonly outputs: readonly RecordOutput[] = DEFAULT_RECORD_OUTPUTS,
    private readonly logger: Pick<Console, "warn"> = console,
  ) {}

  /** Outcome per output file (empty when the scan's template has none). */
  async export(scan: Scan): Promise<{ path: string; outcome: RecordOutcome }[]> {
    if (!scan.templateId || !this.vault.status().configured) return [];
    const outputs = this.outputs.filter((output) => output.templateId === scan.templateId);
    const results: { path: string; outcome: RecordOutcome }[] = [];
    for (const output of outputs) {
      try {
        results.push({ path: output.path, outcome: await this.write(scan, output) });
      } catch (error) {
        this.logger.warn(`[scan-records] could not update ${output.path}: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    return results;
  }

  private async write(scan: Scan, output: RecordOutput): Promise<RecordOutcome> {
    const incoming = recordFor(scan);
    if (!incoming) return "no-data";
    // a write that loses a race with an edit (the dataviewjs tool saving docNo/done) is retried on the new version
    for (let attempt = 0; attempt < 3; attempt += 1) {
      let text: string | null = null;
      let etag: string | undefined;
      try {
        const file = await this.vault.read(output.path);
        text = file.body.toString("utf8");
        etag = file.etag;
      } catch (error) {
        if (!(error instanceof AppError && error.status === 404)) throw error;
      }
      if (text === null && !output.create) return "no-file";
      let array: unknown[] = [];
      if (text !== null && text.replace(/^﻿/, "").trim() !== "") {
        try {
          const parsed: unknown = JSON.parse(text.replace(/^﻿/, ""));
          if (!Array.isArray(parsed)) return "invalid-file";
          array = parsed;
        } catch {
          return "invalid-file";
        }
      }
      const result = upsertRecord(array, incoming, output, [scan.id]);
      if (result.outcome === "skipped" || result.outcome === "unchanged") return result.outcome;
      try {
        await this.vault.write(output.path, Buffer.from(`${JSON.stringify(result.array, null, 2)}\n`, "utf8"), {
          ...(etag ? { ifMatch: etag } : { ifNoneMatch: "*" }),
          client: "scans",
        });
        return result.outcome;
      } catch (error) {
        if (!(error instanceof AppError && error.status === 412) || attempt === 2) throw error;
      }
    }
    return "unchanged";
  }
}
