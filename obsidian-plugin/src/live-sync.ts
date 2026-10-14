// Pure logic for「即時同步」: long-polls the server's vault change feed (GET /v1/vault/changes, see docs/API.md
// 「變更通知（即時同步）」), runs Remotely Save when another device changed something, and reports this device's own
// edits (POST /v1/vault/changes) after Remotely Save has uploaded them. Timers are injectable.
// No "obsidian" imports — unit-tested with fake timers.

import { REMOTELY_SAVE_PLUGIN_ID, isPluginEnabled } from "./device-setup";
import { ApiError, describeError, type LocalOcrClient } from "./sync-core";

export const CLIENT_HEADER = "X-LocalOCR-Client";
export const CHANGES_PATH = "/v1/vault/changes";
/** Remotely Save's「start sync」command (a manual sync: Remotely Save shows its progress notices). */
export const REMOTELY_SAVE_SYNC_COMMAND = `${REMOTELY_SAVE_PLUGIN_ID}:start-sync`;

/** Seconds the server holds a poll when nothing changed (its maximum; requests time out after 60 s). */
export const POLL_WAIT_SECONDS = 25;
/** At least this long between the starts of two polls, even when the server answers at once. */
export const MIN_POLL_INTERVAL_MS = 1_000;
/** Changes from other devices are gathered this long before Remotely Save runs. */
export const REMOTE_SYNC_DEBOUNCE_MS = 1_000;
/** Remotely Save was already syncing: try again after this long, at most REMOTE_SYNC_MAX_BUSY_RETRIES times. */
export const REMOTE_SYNC_BUSY_RETRY_MS = 3_000;
export const REMOTE_SYNC_MAX_BUSY_RETRIES = 10;
/** Local edits are reported this long after the last one: Remotely Save's sync on save uploads ~3 s after an edit. */
export const LOCAL_REPORT_DEBOUNCE_MS = 8_000;
/** Vault events this soon after live sync started Remotely Save are its downloads, not edits made here. */
export const IGNORE_AFTER_REMOTE_SYNC_MS = 20_000;
/** …and, for a long sync, until this long after it finished. */
export const IGNORE_AFTER_REMOTE_SYNC_END_MS = 2_000;
/** Waits after consecutive failures (the last one repeats). */
export const RETRY_DELAYS_MS: readonly number[] = [5_000, 15_000, 60_000];
/** Old server without the change feed (404), no vault (503) or a rejected API key: retry rarely and quietly. */
export const SLOW_RETRY_MS = 10 * 60_000;
/** Most paths in one report (the server's limit); more are reported as "something changed" (no paths). */
export const MAX_REPORT_PATHS = 100;

export type VaultChangeOp = "write" | "delete" | "external";

/** One entry of GET /v1/vault/changes. */
export interface VaultChange {
	seq: number;
	path: string | null;
	op: VaultChangeOp;
	/** X-LocalOCR-Client of whoever made the change ("mcp" for Claude), null when unknown. */
	client: string | null;
	at: string;
}

export interface VaultChanges {
	/** "<epoch>:<seq>", sent back as `since`. */
	cursor: string;
	/** The server could not list what changed (restart, gap, too many): sync everything. */
	reset: boolean;
	changes: VaultChange[];
}

/** What starting a Remotely Save sync did. */
export type RemoteSyncResult = "started" | "busy" | "unavailable";

// ---------------------------------------------------------------------------
// Requests and responses

/** GET path: no `since` on the first call (the server answers the current cursor at once). */
export function changesPath(since: string | null, waitSeconds = POLL_WAIT_SECONDS): string {
	if (since === null) return CHANGES_PATH;
	return `${CHANGES_PATH}?since=${encodeURIComponent(since)}&wait=${encodeURIComponent(String(waitSeconds))}`;
}

const isObject = (value: unknown): value is Record<string, unknown> =>
	!!value && typeof value === "object" && !Array.isArray(value);

const OPS: ReadonlySet<string> = new Set(["write", "delete", "external"]);

function parseChange(value: unknown): VaultChange | null {
	if (!isObject(value)) return null;
	const { seq, path, op, client, at } = value;
	if (typeof seq !== "number" || !Number.isFinite(seq)) return null;
	if (path !== null && typeof path !== "string") return null;
	if (typeof op !== "string" || !OPS.has(op)) return null;
	if (client !== null && typeof client !== "string") return null;
	return { seq, path, op: op as VaultChangeOp, client, at: typeof at === "string" ? at : "" };
}

/** Checks a GET /v1/vault/changes body; entries in an unknown shape are skipped. */
export function parseVaultChanges(body: unknown): VaultChanges {
	if (!isObject(body) || typeof body.cursor !== "string" || !body.cursor || typeof body.reset !== "boolean" || !Array.isArray(body.changes)) {
		throw new ApiError("伺服器 /v1/vault/changes 回應格式不正確", 200, "bad_response");
	}
	const changes = body.changes.map(parseChange).filter((change): change is VaultChange => change !== null);
	return { cursor: body.cursor, reset: body.reset, changes };
}

/** Whether a response calls for a Remotely Save sync: a change made by another client, or a reset. */
export function hasRemoteChanges(response: VaultChanges, clientId: string): boolean {
	return response.reset || response.changes.some((change) => change.client !== clientId);
}

/** Old server, no vault or a rejected key: nothing to gain from retrying soon. */
export function isSlowFailure(error: unknown): boolean {
	if (!(error instanceof ApiError)) return false;
	return error.status === 404 || error.isAuthError || error.code === "vault_not_configured";
}

/** How long to wait after the `failures`-th consecutive failure (1-based). */
export function retryDelay(error: unknown, failures: number): number {
	if (isSlowFailure(error)) return SLOW_RETRY_MS;
	return RETRY_DELAYS_MS[Math.min(Math.max(failures, 1), RETRY_DELAYS_MS.length) - 1];
}

// ---------------------------------------------------------------------------
// Device id and paths

const ID_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789";
const CLIENT_ID_PATTERN = /^obsidian-[a-z0-9]{8,40}$/;

const cryptoRandom = (length: number): Uint8Array => crypto.getRandomValues(new Uint8Array(length));

/** "obsidian-" + 12 random characters: this device's X-LocalOCR-Client. */
export function createClientId(randomBytes: (length: number) => Uint8Array = cryptoRandom): string {
	const bytes = randomBytes(12);
	let id = "";
	for (let i = 0; i < 12; i++) id += ID_ALPHABET[(bytes[i] ?? 0) % ID_ALPHABET.length];
	return `obsidian-${id}`;
}

export function isClientId(value: unknown): value is string {
	return typeof value === "string" && CLIENT_ID_PATTERN.test(value);
}

/** Notes and attachments only: not the config folder (.obsidian) or any dot file or folder (Remotely Save skips those). */
export function isReportablePath(path: string, configDir: string): boolean {
	if (!path || path === configDir || path.startsWith(`${configDir}/`)) return false;
	return !path.split("/").some((segment) => segment.startsWith("."));
}

/** Changed paths waiting to be reported, deduplicated. */
export class PathQueue {
	private readonly paths = new Set<string>();

	add(path: string): void {
		this.paths.add(path);
	}

	get size(): number {
		return this.paths.size;
	}

	/** Empties the queue: null when it was empty, [] (= "something changed") when it held more than MAX_REPORT_PATHS. */
	take(): string[] | null {
		if (this.paths.size === 0) return null;
		const paths = [...this.paths];
		this.paths.clear();
		return paths.length > MAX_REPORT_PATHS ? [] : paths;
	}

	clear(): void {
		this.paths.clear();
	}
}

// ---------------------------------------------------------------------------
// Timers

export interface Timers {
	setTimeout(callback: () => void, ms: number): unknown;
	clearTimeout(handle: unknown): void;
}

/** The global timers (window's in Obsidian); vitest's fake timers replace them in tests. */
export const globalTimers: Timers = {
	setTimeout: (callback, ms) => globalThis.setTimeout(callback, ms),
	clearTimeout: (handle) => globalThis.clearTimeout(handle as ReturnType<typeof globalThis.setTimeout>),
};

/** Runs `callback` once, `delayMs` after the latest schedule() call. */
export class Debouncer {
	private handle: unknown = null;

	constructor(
		private readonly callback: () => void,
		private readonly delayMs: number,
		private readonly timers: Timers = globalTimers,
	) {}

	get pending(): boolean {
		return this.handle !== null;
	}

	/** (Re)starts the wait; `delayMs` overrides the default for this time. */
	schedule(delayMs = this.delayMs): void {
		this.cancel();
		this.handle = this.timers.setTimeout(() => {
			this.handle = null;
			this.callback();
		}, delayMs);
	}

	cancel(): void {
		if (this.handle === null) return;
		this.timers.clearTimeout(this.handle);
		this.handle = null;
	}
}

// ---------------------------------------------------------------------------
// Remotely Save

interface RemotelySavePlugin {
	/** Newer versions: true while a sync runs. */
	isSyncing?: unknown;
	/** Older versions: "idle" (or "finish") unless a sync runs. */
	syncStatus?: unknown;
	syncRun?: (triggerSource: string) => unknown;
}

/**
 * Starts a Remotely Save sync and resolves when it has finished (as far as can be told). Prefers the plugin's own
 * `syncRun("auto")` (internal API: what its scheduled sync calls, without progress notices) and falls back to the
 * public「start sync」command. "busy" while Remotely Save is already syncing, "unavailable" when it is not enabled.
 */
export async function startRemotelySaveSync(app: unknown): Promise<RemoteSyncResult> {
	if (isPluginEnabled(app, REMOTELY_SAVE_PLUGIN_ID) === false) return "unavailable";
	const host = app as
		| {
				plugins?: { plugins?: Record<string, RemotelySavePlugin | undefined> };
				commands?: { executeCommandById?: (id: string) => unknown };
		  }
		| null
		| undefined;
	const plugin = host?.plugins?.plugins?.[REMOTELY_SAVE_PLUGIN_ID];
	const status = plugin?.syncStatus;
	if (plugin?.isSyncing === true || (typeof status === "string" && status !== "idle" && status !== "finish")) return "busy";
	if (typeof plugin?.syncRun === "function") {
		await plugin.syncRun("auto");
		return "started";
	}
	const commands = host?.commands;
	if (typeof commands?.executeCommandById === "function" && commands.executeCommandById.call(commands, REMOTELY_SAVE_SYNC_COMMAND)) {
		return "started";
	}
	return "unavailable";
}

// ---------------------------------------------------------------------------
// The live-sync loop

export type LiveSyncState = "stopped" | "connecting" | "connected" | "retrying" | "unsupported";

export interface LiveSyncStatus {
	state: LiveSyncState;
	/** When changes from another device last started a Remotely Save sync (ms since the epoch). */
	lastRemoteChangeAt: number | null;
	/** When this device last told the others about its own edits. */
	lastReportAt: number | null;
	/** The latest failure while not connected. */
	error: string | null;
	/** The last attempt to start Remotely Save found it missing or disabled. */
	remotelySaveUnavailable: boolean;
}

export interface LiveSyncDeps {
	client: Pick<LocalOcrClient, "requestJson">;
	/** This device's X-LocalOCR-Client. */
	clientId: string;
	/** The vault's config folder (".obsidian"): never reported. */
	configDir: string;
	/** Starts Remotely Save's sync (startRemotelySaveSync in the plugin). */
	syncRemote: () => Promise<RemoteSyncResult>;
	timers?: Timers;
	now?: () => number;
	/** Console logging; never shown as a notice. */
	log?: (message: string) => void;
}

/**
 * One device's live sync: start() runs the poll loop until stop(). Obsidian's requestUrl cannot be aborted,
 * so a poll still in flight after stop() finishes on its own and its result is ignored.
 */
export class LiveSync {
	private generation = 0;
	private running = false;
	private wake: (() => void) | null = null;
	private ignoreLocalUntil = 0;
	private remoteSyncRunning = false;
	private remoteSyncAgain = false;
	private busyRetries = 0;
	private readonly queue = new PathQueue();
	private readonly timers: Timers;
	private readonly now: () => number;
	private readonly remoteSync: Debouncer;
	private readonly report: Debouncer;
	private current: LiveSyncStatus = {
		state: "stopped",
		lastRemoteChangeAt: null,
		lastReportAt: null,
		error: null,
		remotelySaveUnavailable: false,
	};

	constructor(private readonly deps: LiveSyncDeps) {
		this.timers = deps.timers ?? globalTimers;
		this.now = deps.now ?? Date.now;
		this.remoteSync = new Debouncer(() => void this.runRemoteSync(), REMOTE_SYNC_DEBOUNCE_MS, this.timers);
		this.report = new Debouncer(() => void this.sendReport(), LOCAL_REPORT_DEBOUNCE_MS, this.timers);
	}

	get status(): LiveSyncStatus {
		return { ...this.current };
	}

	get isRunning(): boolean {
		return this.running;
	}

	start(): void {
		if (this.running) return;
		this.running = true;
		const generation = ++this.generation;
		this.update({ state: "connecting", error: null });
		void this.loop(generation);
	}

	stop(): void {
		if (!this.running) return;
		this.running = false;
		this.generation++;
		this.remoteSync.cancel();
		this.report.cancel();
		this.queue.clear();
		this.wake?.();
		this.update({ state: "stopped" });
	}

	/**
	 * Vault paths created, modified, deleted or renamed here (a rename passes both paths). Reported to the other
	 * devices LOCAL_REPORT_DEBOUNCE_MS after the last one, unless they are Remotely Save downloads this started.
	 */
	noteLocalChange(paths: readonly string[]): void {
		if (!this.running || this.current.state === "unsupported") return;
		if (this.now() < this.ignoreLocalUntil) return;
		let added = false;
		for (const path of paths) {
			if (!isReportablePath(path, this.deps.configDir)) continue;
			this.queue.add(path);
			added = true;
		}
		if (added) this.report.schedule();
	}

	private headers(): Record<string, string> {
		return { [CLIENT_HEADER]: this.deps.clientId };
	}

	private update(patch: Partial<LiveSyncStatus>): void {
		this.current = { ...this.current, ...patch };
	}

	private log(message: string): void {
		this.deps.log?.(message);
	}

	private async loop(generation: number): Promise<void> {
		let cursor: string | null = null;
		let failures = 0;
		while (generation === this.generation) {
			const startedAt = this.now();
			try {
				const body = await this.deps.client.requestJson(changesPath(cursor), { headers: this.headers() });
				if (generation !== this.generation) return;
				const response = parseVaultChanges(body);
				if (cursor !== null && hasRemoteChanges(response, this.deps.clientId)) {
					this.update({ lastRemoteChangeAt: this.now() });
					this.remoteSync.schedule();
				}
				cursor = response.cursor;
				if (failures > 0) this.log("即時同步已重新連線");
				failures = 0;
				this.update({ state: "connected", error: null });
				const elapsed = this.now() - startedAt;
				if (elapsed < MIN_POLL_INTERVAL_MS) await this.sleep(MIN_POLL_INTERVAL_MS - elapsed, generation);
			} catch (error) {
				if (generation !== this.generation) return;
				failures += 1;
				const slow = isSlowFailure(error);
				const message = describeError(error);
				if (failures === 1) this.log(`即時同步連線失敗，稍後重試：${message}`);
				this.update({ state: slow ? "unsupported" : "retrying", error: message });
				await this.sleep(retryDelay(error, failures), generation);
			}
		}
	}

	/** Resolves after `ms`, or at once when stop() is called. */
	private sleep(ms: number, generation: number): Promise<void> {
		return new Promise((resolve) => {
			if (generation !== this.generation) {
				resolve();
				return;
			}
			const done = () => {
				this.wake = null;
				resolve();
			};
			const handle = this.timers.setTimeout(done, ms);
			this.wake = () => {
				this.timers.clearTimeout(handle);
				done();
			};
		});
	}

	private async runRemoteSync(): Promise<void> {
		if (this.remoteSyncRunning) {
			this.remoteSyncAgain = true;
			return;
		}
		const generation = this.generation;
		this.remoteSyncRunning = true;
		const previousIgnore = this.ignoreLocalUntil;
		this.ignoreLocalUntil = Math.max(previousIgnore, this.now() + IGNORE_AFTER_REMOTE_SYNC_MS);
		let result: RemoteSyncResult;
		try {
			result = await this.deps.syncRemote();
		} catch (error) {
			this.log(`無法執行 Remotely Save 同步：${describeError(error)}`);
			result = "unavailable";
		}
		if (result === "started") {
			this.ignoreLocalUntil = Math.max(this.ignoreLocalUntil, this.now() + IGNORE_AFTER_REMOTE_SYNC_END_MS);
		} else {
			this.ignoreLocalUntil = previousIgnore; // nothing was downloaded on our behalf
		}
		this.remoteSyncRunning = false;
		if (generation !== this.generation) return;
		this.update({ remotelySaveUnavailable: result === "unavailable" });
		if (result === "busy" && this.busyRetries < REMOTE_SYNC_MAX_BUSY_RETRIES) {
			// Remotely Save is in the middle of its own sync, which may have listed the bucket before the change
			this.busyRetries += 1;
			this.remoteSync.schedule(REMOTE_SYNC_BUSY_RETRY_MS);
			return;
		}
		this.busyRetries = 0;
		if (this.remoteSyncAgain) {
			this.remoteSyncAgain = false;
			this.remoteSync.schedule();
		}
	}

	private async sendReport(): Promise<void> {
		const paths = this.queue.take();
		if (paths === null || !this.running) return;
		const generation = this.generation;
		try {
			await this.deps.client.requestJson(CHANGES_PATH, { method: "POST", body: { paths }, headers: this.headers() });
			if (generation === this.generation) this.update({ lastReportAt: this.now() });
		} catch (error) {
			// The edit still reaches the bucket through Remotely Save; the other devices just hear of it later.
			this.log(`無法通知其他裝置：${describeError(error)}`);
		}
	}
}

/** One line for the settings tab. `formatTime` renders milliseconds since the epoch. */
export function describeLiveSync(status: LiveSyncStatus, formatTime: (ms: number) => string): string {
	const parts: string[] = [];
	switch (status.state) {
		case "stopped":
			parts.push("未啟動。");
			break;
		case "connecting":
			parts.push("連線中…");
			break;
		case "connected":
			parts.push("已連線，等待其他裝置的修改。");
			break;
		case "retrying":
			parts.push(`連線中斷，稍後自動重試${status.error ? `（${status.error}）` : ""}。`);
			break;
		case "unsupported":
			parts.push(
				`目前無法使用${status.error ? `（${status.error}）` : ""}：伺服器可能是舊版或尚未設定儲存桶，10 分鐘後再試。`,
			);
			break;
	}
	if (status.lastRemoteChangeAt !== null) parts.push(`上次收到其他裝置的修改：${formatTime(status.lastRemoteChangeAt)}。`);
	if (status.lastReportAt !== null) parts.push(`上次通知其他裝置：${formatTime(status.lastReportAt)}。`);
	if (status.remotelySaveUnavailable) parts.push("這台裝置尚未啟用 Remotely Save，無法自動同步。");
	return parts.join("");
}
