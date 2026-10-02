// Pure sync logic: REST client over an injected HTTP transport, cursor
// bookkeeping and the paging loop. No "obsidian" imports — unit-tested.

import type { JsonOutcome } from "./json-export";
import type { HealthResponse, Scan, ScanPage, SyncCursorState, Template, WriteOutcome } from "./types";

export const PAGE_SIZE = 100;
/** Sent on the very first sync so the server uses ascending `updatedAt` order. */
export const EPOCH = "1970-01-01T00:00:00.000Z";
export const REQUEST_TIMEOUT_MS = 60_000;

// ---------------------------------------------------------------------------
// HTTP client

export interface HttpRequest {
	url: string;
	method: "GET";
	headers: Record<string, string>;
}

export interface HttpResponse {
	status: number;
	text: string;
}

export type HttpFn = (request: HttpRequest) => Promise<HttpResponse>;

export class ApiError extends Error {
	constructor(
		message: string,
		public readonly status: number,
		public readonly code?: string,
	) {
		super(message);
		this.name = "ApiError";
	}

	get isAuthError(): boolean {
		return this.status === 401 || this.status === 403;
	}
}

/** Trim whitespace and trailing slashes; assume https:// when no scheme is given. */
export function normalizeServerUrl(url: string): string {
	let value = url.trim().replace(/\/+$/, "");
	if (value && !/^[a-z][a-z0-9+.-]*:\/\//i.test(value)) value = `https://${value}`;
	return value;
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
	return new Promise<T>((resolve, reject) => {
		const timer: ReturnType<typeof setTimeout> = setTimeout(
			() => reject(new ApiError(`連線逾時（${Math.round(ms / 1000)} 秒）`, 0, "timeout")),
			ms,
		);
		promise.then(
			(value) => {
				clearTimeout(timer);
				resolve(value);
			},
			(error: unknown) => {
				clearTimeout(timer);
				reject(error);
			},
		);
	});
}

function statusMessage(status: number, serverMessage?: string): string {
	const detail = serverMessage ? `：${serverMessage}` : "";
	if (status === 401) return `API 金鑰無效或未提供（401）${detail}`;
	if (status === 403) return `API 金鑰沒有權限（403）${detail}`;
	if (status === 404) return `找不到端點，請確認伺服器網址（404）${detail}`;
	if (status === 429) return `請求過於頻繁，請稍後再試（429）${detail}`;
	if (status >= 500) return `伺服器錯誤（${status}）${detail}`;
	return `請求失敗（${status}）${detail}`;
}

export interface ScanQuery {
	limit: number;
	updatedAfter?: string | null;
	cursor?: string | null;
}

export class LocalOcrClient {
	readonly baseUrl: string;

	constructor(
		baseUrl: string,
		private readonly apiKey: string,
		private readonly http: HttpFn,
		private readonly timeoutMs = REQUEST_TIMEOUT_MS,
	) {
		this.baseUrl = normalizeServerUrl(baseUrl);
	}

	private async getJson(path: string, authenticated: boolean): Promise<unknown> {
		if (!this.baseUrl) throw new ApiError("尚未設定伺服器網址", 0, "config");
		if (authenticated && !this.apiKey) throw new ApiError("尚未設定 API 金鑰", 0, "config");
		const headers: Record<string, string> = { Accept: "application/json" };
		if (authenticated) headers.Authorization = `Bearer ${this.apiKey}`;
		let response: HttpResponse;
		try {
			response = await withTimeout(this.http({ url: this.baseUrl + path, method: "GET", headers }), this.timeoutMs);
		} catch (error) {
			if (error instanceof ApiError) throw error;
			const reason = error instanceof Error ? error.message : String(error);
			throw new ApiError(`無法連線到伺服器：${reason}`, 0, "network");
		}
		let body: unknown = undefined;
		if (response.text) {
			try {
				body = JSON.parse(response.text);
			} catch {
				body = undefined;
			}
		}
		if (response.status < 200 || response.status >= 300) {
			const err = (body as { error?: { code?: unknown; message?: unknown } } | undefined)?.error;
			const code = typeof err?.code === "string" ? err.code : undefined;
			const message = typeof err?.message === "string" ? err.message : undefined;
			throw new ApiError(statusMessage(response.status, message), response.status, code);
		}
		if (body === undefined) throw new ApiError("伺服器回應不是有效的 JSON", response.status, "bad_response");
		return body;
	}

	async health(): Promise<HealthResponse> {
		const body = (await this.getJson("/health", false)) as Partial<HealthResponse> | null;
		if (!body || typeof body !== "object" || typeof body.status !== "string") {
			throw new ApiError("伺服器 /health 回應格式不正確", 200, "bad_response");
		}
		return body as HealthResponse;
	}

	async listTemplates(): Promise<Template[]> {
		const body = (await this.getJson("/v1/templates", true)) as { items?: unknown } | null;
		if (!body || !Array.isArray(body.items)) {
			throw new ApiError("伺服器 /v1/templates 回應格式不正確", 200, "bad_response");
		}
		return body.items.filter(
			(t): t is Template => !!t && typeof (t as Template).id === "string" && typeof (t as Template).name === "string",
		);
	}

	async listScans(query: ScanQuery): Promise<ScanPage> {
		const params = [`limit=${encodeURIComponent(String(query.limit))}`];
		if (query.updatedAfter) params.push(`updatedAfter=${encodeURIComponent(query.updatedAfter)}`);
		if (query.cursor) params.push(`cursor=${encodeURIComponent(query.cursor)}`);
		const body = (await this.getJson(`/v1/scans?${params.join("&")}`, true)) as {
			items?: unknown;
			nextCursor?: unknown;
		} | null;
		if (!body || !Array.isArray(body.items)) {
			throw new ApiError("伺服器 /v1/scans 回應格式不正確", 200, "bad_response");
		}
		const nextCursor = typeof body.nextCursor === "string" && body.nextCursor ? body.nextCursor : null;
		return { items: body.items as Scan[], nextCursor };
	}
}

export function templateNameMap(templates: Template[]): Map<string, string> {
	const map = new Map<string, string>();
	for (const t of templates) map.set(t.id, t.name);
	return map;
}

/** Human-readable (Traditional Chinese) message for any error. Never includes the API key. */
export function describeError(error: unknown): string {
	if (error instanceof Error) return error.message || error.name;
	return String(error);
}

// ---------------------------------------------------------------------------
// Cursor bookkeeping

export function initialCursorState(): SyncCursorState {
	return { cursor: null, updatedAfter: null, lastSeenUpdatedAt: null };
}

/**
 * Query for the next page. The first sync sends `updatedAfter=EPOCH` so the
 * server returns everything in ascending `updatedAt` order (without either
 * parameter it would sort by `createdAt` descending). While following a cursor
 * the same `updatedAfter` is re-sent so the opaque cursor sees the same query.
 */
export function nextScanQuery(state: SyncCursorState, limit = PAGE_SIZE): ScanQuery {
	const query: ScanQuery = { limit, updatedAfter: state.updatedAfter ?? EPOCH };
	if (state.cursor) query.cursor = state.cursor;
	return query;
}

function timeOf(iso: string | null | undefined): number {
	if (typeof iso !== "string") return Number.NaN;
	return new Date(iso).getTime();
}

/** `updatedAt` of the last item that has one (items are ascending). */
export function lastUpdatedAt(items: ReadonlyArray<Partial<Scan>>): string | null {
	for (let i = items.length - 1; i >= 0; i--) {
		const value = items[i]?.updatedAt;
		if (typeof value === "string" && !Number.isNaN(timeOf(value))) return value;
	}
	return null;
}

function laterOf(a: string | null, b: string | null): string | null {
	if (!a) return b;
	if (!b) return a;
	return timeOf(b) >= timeOf(a) ? b : a;
}

export interface CursorAdvance {
	state: SyncCursorState;
	/** True when there is nothing more to fetch in this run. */
	done: boolean;
}

/**
 * Bookkeeping after a page has been written:
 * - `nextCursor` present → persist it and keep paging (stop on an empty page or
 *   a repeated cursor, keeping the cursor for the next run);
 * - `nextCursor` null → remember the newest `updatedAt` as `updatedAfter` and
 *   clear the cursor.
 */
export function advanceCursor(state: SyncCursorState, page: ScanPage): CursorAdvance {
	const lastSeen = laterOf(state.lastSeenUpdatedAt, lastUpdatedAt(page.items));
	if (page.nextCursor) {
		const done = page.items.length === 0 || page.nextCursor === state.cursor;
		return {
			state: { cursor: page.nextCursor, updatedAfter: state.updatedAfter, lastSeenUpdatedAt: lastSeen },
			done,
		};
	}
	return {
		state: { cursor: null, updatedAfter: lastSeen ?? state.updatedAfter, lastSeenUpdatedAt: lastSeen },
		done: true,
	};
}

// ---------------------------------------------------------------------------
// Sync loop

export interface JsonCounts {
	created: number;
	updated: number;
	skipped: number;
	unchanged: number;
	failed: number;
}

export interface SyncResult {
	/** Note outcomes. */
	created: number;
	updated: number;
	unchanged: number;
	failed: number;
	/** JSON-array export outcomes. */
	json: JsonCounts;
	/** Scans whose note or JSON record was created or updated. */
	changed: number;
	pages: number;
	/** First few distinct error messages. */
	errors: string[];
}

export function emptySyncResult(): SyncResult {
	return {
		created: 0,
		updated: 0,
		unchanged: 0,
		failed: 0,
		json: { created: 0, updated: 0, skipped: 0, unchanged: 0, failed: 0 },
		changed: 0,
		pages: 0,
		errors: [],
	};
}

function pushError(result: SyncResult, message: string): void {
	if (result.errors.length < 5 && !result.errors.includes(message)) result.errors.push(message);
}

export class SyncAbortedError extends Error {
	constructor(
		public readonly reason: unknown,
		public readonly result: SyncResult,
	) {
		super(describeError(reason));
		this.name = "SyncAbortedError";
	}
}

export interface SyncDeps {
	client: Pick<LocalOcrClient, "listTemplates" | "listScans">;
	/** Saved progress to resume from. */
	state: SyncCursorState;
	/** Create or update the note for one scan (omit when notes are disabled). */
	writeScan?(scan: Scan, templates: ReadonlyMap<string, string>): Promise<WriteOutcome>;
	/** Upsert the scan into its JSON array file; null when the scan has no JSON mapping. */
	exportJson?(scan: Scan): Promise<JsonOutcome | null>;
	/** Persist progress (called after every page). */
	saveState(state: SyncCursorState): Promise<void>;
	pageSize?: number;
	maxPages?: number;
	/** Polled between scans; return true to stop early (e.g. plugin unloading). */
	isCancelled?(): boolean;
	onProgress?(result: SyncResult): void;
}

export function isValidScan(item: unknown): item is Scan {
	const scan = item as Partial<Scan> | null;
	return (
		!!scan &&
		typeof scan === "object" &&
		typeof scan.id === "string" &&
		scan.id.length > 0 &&
		typeof scan.updatedAt === "string"
	);
}

export async function runSync(deps: SyncDeps): Promise<SyncResult> {
	const result = emptySyncResult();
	const pageSize = deps.pageSize ?? PAGE_SIZE;
	const maxPages = deps.maxPages ?? 10_000;
	let state: SyncCursorState = { ...deps.state };
	try {
		const templates = templateNameMap(await deps.client.listTemplates());
		for (;;) {
			if (deps.isCancelled?.()) break;
			const page = await deps.client.listScans(nextScanQuery(state, pageSize));
			result.pages++;
			for (const item of page.items) {
				if (deps.isCancelled?.()) return result; // progress for this page is not saved
				if (!isValidScan(item)) {
					result.failed++;
					pushError(result, "伺服器回傳了格式不正確的掃描紀錄");
					continue;
				}
				let changed = false;
				if (deps.writeScan) {
					try {
						const outcome = await deps.writeScan(item, templates);
						result[outcome]++;
						changed = outcome !== "unchanged";
					} catch (error) {
						result.failed++;
						pushError(result, `${item.id}：${describeError(error)}`);
					}
				}
				if (deps.exportJson) {
					try {
						const outcome = await deps.exportJson(item);
						if (outcome) {
							result.json[outcome]++;
							changed ||= outcome === "created" || outcome === "updated";
						}
					} catch (error) {
						result.json.failed++;
						pushError(result, describeError(error));
					}
				}
				if (changed) result.changed++;
			}
			const advance = advanceCursor(state, page);
			state = advance.state;
			await deps.saveState(state);
			deps.onProgress?.(result);
			if (advance.done || result.pages >= maxPages) break;
		}
	} catch (error) {
		throw new SyncAbortedError(error, result);
	}
	return result;
}

/**
 * One-line summary such as「新增 3 筆、更新 1 筆；JSON：新增 1 筆、更新 0 筆、略過 2 筆」.
 * The JSON part appears when there was JSON activity or notes are disabled.
 */
export function summarize(result: SyncResult, opts: { notes?: boolean } = {}): string {
	const notes = opts.notes ?? true;
	const sections: string[] = [];
	if (notes) {
		const parts = [`新增 ${result.created} 筆`, `更新 ${result.updated} 筆`];
		if (result.unchanged) parts.push(`未變更 ${result.unchanged} 筆`);
		if (result.failed) parts.push(`失敗 ${result.failed} 筆`);
		sections.push(parts.join("、"));
	}
	const j = result.json;
	if (!notes || j.created + j.updated + j.skipped + j.unchanged + j.failed > 0) {
		const parts = [`新增 ${j.created} 筆`, `更新 ${j.updated} 筆`, `略過 ${j.skipped} 筆`];
		if (j.failed) parts.push(`失敗 ${j.failed} 筆`);
		sections.push(`JSON：${parts.join("、")}`);
	}
	if (!notes && result.failed) sections.push(`失敗 ${result.failed} 筆`);
	return sections.join("；");
}
