// Pure logic for the "JSON 陣列輸出" feature: upsert a scan's `data` object into
// a JSON array file (newest first). No "obsidian" imports — unit-tested.

import type { Scan } from "./types";

export interface JsonMapping {
	/** Template id (情境代碼), e.g. `fv60_air`. */
	templateId: string;
	/** Vault path of the JSON array file. */
	filePath: string;
}

/** Where the record written for a scan lives (persisted per scan id). */
export interface JsonRecordRef {
	filePath: string;
	recordId: string;
}

export type JsonOutcome = "created" | "updated" | "skipped" | "unchanged";

export interface UpsertOptions {
	/** Fields whose existing values survive an update (e.g. `docNo`, `done`). */
	preserveFields: string[];
	/** Field that marks a record as finished; finished records are never touched. Empty = none. */
	doneField: string;
}

export interface PreparedRecord {
	record: Record<string, unknown>;
	recordId: string;
}

export class JsonArrayError extends Error {
	constructor(message: string) {
		super(message);
		this.name = "JsonArrayError";
	}
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** `"docNo, done"` → `["docNo", "done"]` (also accepts ，、; and newlines). */
export function parseFieldList(value: string): string[] {
	const fields: string[] = [];
	for (const part of value.split(/[,，、;；\n]/)) {
		const field = part.trim();
		if (field && !fields.includes(field)) fields.push(field);
	}
	return fields;
}

/** First mapping whose template id matches (rows with empty fields are ignored). */
export function findMapping(mappings: ReadonlyArray<JsonMapping>, templateId: string | null | undefined): JsonMapping | null {
	if (!templateId) return null;
	for (const mapping of mappings) {
		if (mapping.templateId.trim() === templateId && mapping.filePath.trim()) return mapping;
	}
	return null;
}

/** The record's id as a string, or null when it has no usable id. */
export function recordIdOf(item: unknown): string | null {
	if (!isPlainObject(item)) return null;
	const id = item.id;
	if (typeof id === "string" && id.trim()) return id;
	if (typeof id === "number" && Number.isFinite(id)) return String(id);
	return null;
}

/**
 * The record to write for a scan: its `data` object as received (key order
 * kept). When `data` has no usable `id`, the scan id is used — in place if an
 * empty `id` key exists, otherwise as the first key. Returns null when `data`
 * is not a JSON object.
 */
export function prepareRecord(scan: Pick<Scan, "id" | "data">): PreparedRecord | null {
	if (!isPlainObject(scan.data)) return null;
	const existingId = recordIdOf(scan.data);
	if (existingId !== null) return { record: { ...scan.data }, recordId: existingId };
	const record: Record<string, unknown> = "id" in scan.data ? { ...scan.data, id: scan.id } : { id: scan.id, ...scan.data };
	return { record, recordId: scan.id };
}

/** Parse a JSON array file. Empty text counts as an empty array. */
export function parseJsonArray(text: string, filePath = "JSON 檔案"): unknown[] {
	const trimmed = text.replace(/^\uFEFF/, "").trim();
	if (!trimmed) return [];
	let value: unknown;
	try {
		value = JSON.parse(trimmed);
	} catch (error) {
		const reason = error instanceof Error ? error.message : String(error);
		throw new JsonArrayError(`「${filePath}」不是有效的 JSON（${reason}），已略過，不會覆寫`);
	}
	if (!Array.isArray(value)) {
		throw new JsonArrayError(`「${filePath}」的內容不是 JSON 陣列，已略過，不會覆寫`);
	}
	return value;
}

export function serializeJsonArray(array: unknown[]): string {
	return `${JSON.stringify(array, null, 2)}\n`;
}

/**
 * `incoming` with the existing values of `fields` kept. Preserved fields that
 * `incoming` also has keep their position; others are appended.
 */
export function mergePreserved(
	existing: Record<string, unknown>,
	incoming: Record<string, unknown>,
	fields: ReadonlyArray<string>,
): Record<string, unknown> {
	const merged: Record<string, unknown> = { ...incoming };
	for (const field of fields) {
		if (Object.prototype.hasOwnProperty.call(existing, field)) merged[field] = existing[field];
	}
	return merged;
}

export interface UpsertResult {
	array: unknown[];
	outcome: JsonOutcome;
	/** Index of the record in `array`. */
	index: number;
}

/**
 * Insert or update `record` in `array` (not mutated):
 * - no item with a matching `id` → insert at index 0 (newest first);
 * - match whose done field is truthy → untouched (`skipped`);
 * - otherwise replace in place, keeping the preserved fields' existing values.
 * Items are matched only by `id` (`recordId`, then any of `altIds`), so records
 * the plugin did not create are never modified.
 */
export function upsertRecord(
	array: ReadonlyArray<unknown>,
	prepared: PreparedRecord,
	opts: UpsertOptions,
	altIds: ReadonlyArray<string> = [],
): UpsertResult {
	let index = -1;
	for (const id of [prepared.recordId, ...altIds]) {
		index = array.findIndex((item) => recordIdOf(item) === id);
		if (index >= 0) break;
	}
	if (index < 0) return { array: [prepared.record, ...array], outcome: "created", index: 0 };

	const existing = array[index] as Record<string, unknown>;
	const doneField = opts.doneField.trim();
	if (doneField && existing[doneField]) return { array: [...array], outcome: "skipped", index };

	const merged = mergePreserved(existing, prepared.record, opts.preserveFields);
	if (JSON.stringify(merged) === JSON.stringify(existing)) return { array: [...array], outcome: "unchanged", index };
	const next = [...array];
	next[index] = merged;
	return { array: next, outcome: "updated", index };
}

export interface UpsertTextResult {
	/** New file content, or null when nothing needs to be written. */
	text: string | null;
	outcome: JsonOutcome;
}

/**
 * Apply `upsertRecord` to a file's text (`null` = the file does not exist yet).
 * Throws JsonArrayError when an existing file is not a JSON array.
 */
export function upsertIntoJsonText(
	text: string | null,
	prepared: PreparedRecord,
	opts: UpsertOptions,
	altIds: ReadonlyArray<string> = [],
	filePath?: string,
): UpsertTextResult {
	if (text === null) return { text: serializeJsonArray([prepared.record]), outcome: "created" };
	const result = upsertRecord(parseJsonArray(text, filePath), prepared, opts, altIds);
	if (result.outcome === "skipped" || result.outcome === "unchanged") return { text: null, outcome: result.outcome };
	return { text: serializeJsonArray(result.array), outcome: result.outcome };
}
