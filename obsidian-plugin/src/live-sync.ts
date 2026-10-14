// Pure logic for「即時同步」: listens to the server's vault change feed — pushed over the WebSocket
// GET /v1/vault/stream, or long-polled from GET /v1/vault/changes when the WebSocket cannot be used (see docs/API.md
// 「變更通知（即時同步）」) — runs Remotely Save when another device changed something, and reports this device's own
// edits (a stream "report" message, or POST /v1/vault/changes) after Remotely Save has uploaded them.
// Timers and the WebSocket are injectable. No "obsidian" imports — unit-tested with fake timers.

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

export const STREAM_PATH = "/v1/vault/stream";
/** A {"type":"ping"} this often (the server answers pong), so a dead connection is noticed. */
export const STREAM_PING_INTERVAL_MS = 30_000;
/** No message at all for this long (not even a pong): the connection is dead, reconnect. */
export const STREAM_IDLE_TIMEOUT_MS = 75_000;
/** Waits before reconnecting: 1 s after a working connection ended, longer after each failed attempt (the last repeats). */
export const STREAM_RETRY_DELAYS_MS: readonly number[] = [1_000, 2_000, 5_000, 15_000, 60_000];
/** The server has no vault storage (close 4503): try again after this long. */
export const STREAM_NOT_CONFIGURED_RETRY_MS = 60_000;
/** This many failed connection attempts in a row before the server ever answered (e.g. an old server: upgrade 404): long-poll instead. */
export const STREAM_FAILURES_BEFORE_POLLING = 3;
/** While long-polling instead, try the WebSocket again this often (the attempts may have failed only because the device was offline). */
export const STREAM_RECHECK_MS = 10 * 60_000;
export const STREAM_CLOSE_UNAUTHORIZED = 4401;
export const STREAM_CLOSE_NOT_CONFIGURED = 4503;
/** The close code of a connection that failed or was given up locally (no close frame). */
export const STREAM_CLOSE_ABNORMAL = 1006;
export const STREAM_UNAUTHORIZED_MESSAGE = "API 金鑰無效或未提供（401）";
export const STREAM_NOT_CONFIGURED_MESSAGE = "伺服器尚未設定 Obsidian 儲存桶（503）";

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
// WebSocket GET /v1/vault/stream

/** The stream's WebSocket URL for a server base URL (http → ws, https → wss, path kept); null for anything else. */
export function streamUrl(baseUrl: string): string | null {
	const match = /^(https?):\/\/(.+)$/i.exec(baseUrl.trim().replace(/\/+$/, ""));
	if (!match) return null;
	return `${match[1].toLowerCase() === "https" ? "wss" : "ws"}://${match[2]}${STREAM_PATH}`;
}

/** A message from the server on the stream. */
export type StreamMessage =
	| { type: "ready"; cursor: string; reset: boolean }
	| { type: "changes"; changes: VaultChanges }
	| { type: "ack" }
	| { type: "pong" }
	| { type: "error"; code: string };

/** Checks a stream message; null for anything unknown or malformed (ignored). */
export function parseStreamMessage(text: string): StreamMessage | null {
	let value: unknown;
	try {
		value = JSON.parse(text);
	} catch {
		return null;
	}
	if (!isObject(value)) return null;
	switch (value.type) {
		case "ready":
			return typeof value.cursor === "string" && value.cursor ? { type: "ready", cursor: value.cursor, reset: value.reset === true } : null;
		case "changes":
			try {
				return { type: "changes", changes: parseVaultChanges(value) };
			} catch {
				return null;
			}
		case "ack":
			return { type: "ack" };
		case "pong":
			return { type: "pong" };
		case "error":
			return typeof value.code === "string" ? { type: "error", code: value.code } : null;
		default:
			return null;
	}
}

export interface StreamHandlers {
	/** The connection is open: send the auth message. */
	open(): void;
	/** A text message. */
	message(data: string): void;
	/** The connection ended or could not be opened (code 1006 then). Not called after StreamConnection.close(). */
	close(code: number): void;
}

export interface StreamConnection {
	/** Throws when the connection is not open. */
	send(data: string): void;
	close(): void;
}

/** Opens a WebSocket; handlers are called asynchronously. */
export type OpenStream = (url: string, handlers: StreamHandlers) => StreamConnection;

/** What LiveSync needs for the stream. */
export interface StreamDeps {
	/** ws(s)://…/v1/vault/stream (streamUrl). */
	url: string;
	/** The API key, sent in the auth message (browsers cannot set headers on a WebSocket). Never logged. */
	token: string;
	open: OpenStream;
}

interface BrowserSocket {
	readyState: number;
	onopen: unknown;
	onmessage: unknown;
	onclose: unknown;
	onerror: unknown;
	send(data: string): void;
	close(code?: number): void;
}

/**
 * OpenStream over the browser WebSocket (desktop and mobile Obsidian); null when there is none. `Socket` is
 * injectable for tests.
 */
export function browserWebSocket(Socket: unknown = (globalThis as { WebSocket?: unknown }).WebSocket): OpenStream | null {
	if (typeof Socket !== "function") return null;
	const Ctor = Socket as new (url: string) => BrowserSocket;
	return (url, handlers) => {
		const socket = new Ctor(url);
		let ended = false;
		const end = (code: number) => {
			if (ended) return;
			ended = true;
			handlers.close(code);
		};
		socket.onopen = () => handlers.open();
		socket.onmessage = (event: { data?: unknown }) => {
			if (typeof event.data === "string") handlers.message(event.data);
		};
		socket.onclose = (event: { code?: unknown }) => end(typeof event.code === "number" ? event.code : STREAM_CLOSE_ABNORMAL);
		// An error means the connection failed. Browsers follow it with a close event (1006), but not every
		// implementation does (Node's WebSocket stays CONNECTING after a refused upgrade), so it ends the connection here.
		socket.onerror = () => end(STREAM_CLOSE_ABNORMAL);
		return {
			send: (data) => socket.send(data),
			close: () => {
				ended = true;
				socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
				try {
					socket.close(1000);
				} catch {
					// already closed
				}
			},
		};
	};
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

/** How the change feed reaches this device: pushed over the WebSocket, or long-polled. */
export type LiveSyncTransport = "stream" | "polling";

export interface LiveSyncStatus {
	state: LiveSyncState;
	/** How the latest connection was made; null before the first one. */
	transport: LiveSyncTransport | null;
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
	/** The WebSocket GET /v1/vault/stream, preferred when given; null or omitted = long-poll only. */
	stream?: StreamDeps | null;
	timers?: Timers;
	now?: () => number;
	/** Console logging; never shown as a notice. */
	log?: (message: string) => void;
}

/** How one stream connection ended. */
interface StreamOutcome {
	/** The server answered ready (the connection worked). */
	ready: boolean;
	/** The close code; the server's error message decides 4401/4503 when it sent one. */
	code: number;
	/** Given up locally: no message for STREAM_IDLE_TIMEOUT_MS. */
	idle: boolean;
}

function describeStreamEnd({ ready, code, idle }: StreamOutcome): string {
	if (idle) return `連線逾時（${STREAM_IDLE_TIMEOUT_MS / 1000} 秒沒有回應）`;
	if (!ready) return "無法建立即時推送連線";
	return code === 1001 ? "伺服器重新啟動" : `即時推送連線中斷（${code}）`;
}

/**
 * One device's live sync: start() keeps a WebSocket to the server's change stream open (or, when that cannot be
 * used, runs the long-poll loop) until stop(). Obsidian's requestUrl cannot be aborted, so a poll still in flight
 * after stop() finishes on its own and its result is ignored.
 */
export class LiveSync {
	private generation = 0;
	private running = false;
	private wake: (() => void) | null = null;
	/** Ends the current stream connection (stop()). */
	private endStream: (() => void) | null = null;
	/** The current stream connection once the server answered ready: reports go over it. */
	private liveStream: StreamConnection | null = null;
	/** The latest cursor, shared by the stream and the long poll; null until the first answer. */
	private cursor: string | null = null;
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
		transport: null,
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
		if (this.deps.stream) void this.streamLoop(generation, false);
		else void this.pollLoop(generation, false);
	}

	stop(): void {
		if (!this.running) return;
		this.running = false;
		this.generation++;
		this.remoteSync.cancel();
		this.report.cancel();
		this.queue.clear();
		this.endStream?.();
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

	/**
	 * An answer from the change feed (poll, stream ready or push): Remotely Save runs (debounced) for another client's
	 * change or a reset, but never for the first answer, which only gives the cursor.
	 */
	private applyChanges(response: VaultChanges): void {
		if (this.cursor !== null && hasRemoteChanges(response, this.deps.clientId)) {
			this.update({ lastRemoteChangeAt: this.now() });
			this.remoteSync.schedule();
		}
		this.cursor = response.cursor;
	}

	/**
	 * Keeps a stream connection open: reconnects after 1/2/5/15/60 s, waits 10 minutes after a rejected key (4401) and
	 * 60 s while the server has no vault (4503). Hands over to the long poll after STREAM_FAILURES_BEFORE_POLLING failed
	 * attempts in a row when the server never answered on the WebSocket. `recheck`: trying the stream again while
	 * long-polling (failed attempts change nothing on show).
	 */
	private async streamLoop(generation: number, recheck: boolean): Promise<void> {
		let answered = false; // the server spoke the stream protocol at least once (ready, 4401 or 4503)
		let retries = 0;
		while (generation === this.generation) {
			const outcome = await this.connectStream(generation);
			if (generation !== this.generation) return;
			if (outcome.code === STREAM_CLOSE_UNAUTHORIZED) {
				if (this.current.error !== STREAM_UNAUTHORIZED_MESSAGE) this.log(`即時同步無法登入：${STREAM_UNAUTHORIZED_MESSAGE}`);
				this.update({ state: "unsupported", error: STREAM_UNAUTHORIZED_MESSAGE });
				answered = true;
				retries = 0;
				await this.sleep(SLOW_RETRY_MS, generation);
				continue;
			}
			if (outcome.code === STREAM_CLOSE_NOT_CONFIGURED) {
				if (this.current.error !== STREAM_NOT_CONFIGURED_MESSAGE) this.log(`即時同步暫停：${STREAM_NOT_CONFIGURED_MESSAGE}`);
				this.update({ state: "retrying", error: STREAM_NOT_CONFIGURED_MESSAGE });
				answered = true;
				retries = 0;
				await this.sleep(STREAM_NOT_CONFIGURED_RETRY_MS, generation);
				continue;
			}
			if (outcome.ready) answered = true;
			retries = outcome.ready ? 1 : retries + 1;
			if (!answered && retries >= STREAM_FAILURES_BEFORE_POLLING) {
				if (!recheck) this.log("無法建立即時推送連線（伺服器可能是舊版，或網路不允許 WebSocket），改用輪詢");
				void this.pollLoop(generation, true);
				return;
			}
			if (!recheck || answered) {
				const message = describeStreamEnd(outcome);
				if (retries === 1) this.log(`即時同步連線中斷，稍後重試：${message}`);
				this.update({ state: "retrying", error: message });
			}
			await this.sleep(STREAM_RETRY_DELAYS_MS[Math.min(retries, STREAM_RETRY_DELAYS_MS.length) - 1], generation);
		}
	}

	/** One stream connection: authenticates, then applies what the server pushes. Resolves when it has ended. */
	private connectStream(generation: number): Promise<StreamOutcome> {
		const stream = this.deps.stream as StreamDeps;
		return new Promise((resolve) => {
			let connection: StreamConnection | null = null;
			let ready = false;
			let done = false;
			let serverError: string | null = null;
			let idleTimer: unknown = null;
			let pingTimer: unknown = null;

			const finish = (code: number, idle = false) => {
				if (done) return;
				done = true;
				this.timers.clearTimeout(idleTimer);
				this.timers.clearTimeout(pingTimer);
				if (this.liveStream === connection) this.liveStream = null;
				this.endStream = null;
				connection?.close();
				if (serverError === "unauthorized") code = STREAM_CLOSE_UNAUTHORIZED;
				else if (serverError === "vault_not_configured") code = STREAM_CLOSE_NOT_CONFIGURED;
				resolve({ ready, code, idle });
			};
			const send = (message: Record<string, unknown>) => {
				try {
					connection?.send(JSON.stringify(message));
				} catch {
					// closing: its close event follows
				}
			};
			const watch = () => {
				this.timers.clearTimeout(idleTimer);
				idleTimer = this.timers.setTimeout(() => finish(STREAM_CLOSE_ABNORMAL, true), STREAM_IDLE_TIMEOUT_MS);
			};
			const ping = () => {
				pingTimer = this.timers.setTimeout(() => {
					send({ type: "ping" });
					ping();
				}, STREAM_PING_INTERVAL_MS);
			};
			const onMessage = (message: StreamMessage) => {
				switch (message.type) {
					case "ready":
						if (ready) return;
						ready = true;
						if (this.current.state === "retrying" || this.current.state === "unsupported") this.log("即時同步已重新連線");
						this.applyChanges({ cursor: message.cursor, reset: message.reset, changes: [] });
						this.liveStream = connection;
						this.update({ state: "connected", transport: "stream", error: null });
						return;
					case "changes":
						if (ready) this.applyChanges(message.changes);
						return;
					case "ack":
						this.update({ lastReportAt: this.now() });
						return;
					case "error":
						serverError = message.code; // the close (4401, 4503) follows
						return;
					case "pong":
						return;
				}
			};

			this.endStream = () => finish(1000);
			watch();
			try {
				connection = stream.open(stream.url, {
					open: () => {
						if (done || generation !== this.generation) return;
						const auth: Record<string, string> = { type: "auth", token: stream.token, client: this.deps.clientId };
						if (this.cursor !== null) auth.since = this.cursor;
						send(auth);
						ping();
					},
					message: (data) => {
						if (done || generation !== this.generation) return;
						watch();
						const message = parseStreamMessage(data);
						if (message) onMessage(message);
					},
					close: (code) => finish(code),
				});
				if (done) connection.close(); // ended while opening
			} catch (error) {
				this.log(`無法開啟即時推送連線：${describeError(error)}`);
				finish(STREAM_CLOSE_ABNORMAL);
			}
		});
	}

	/**
	 * The long poll. `fallback`: started because the stream could not be used; the stream is tried again every
	 * STREAM_RECHECK_MS.
	 */
	private async pollLoop(generation: number, fallback: boolean): Promise<void> {
		const pollingSince = this.now();
		let failures = 0;
		while (generation === this.generation) {
			if (fallback && this.deps.stream && this.now() - pollingSince >= STREAM_RECHECK_MS) {
				void this.streamLoop(generation, true);
				return;
			}
			const startedAt = this.now();
			try {
				const body = await this.deps.client.requestJson(changesPath(this.cursor), { headers: this.headers() });
				if (generation !== this.generation) return;
				this.applyChanges(parseVaultChanges(body));
				if (failures > 0) this.log("即時同步已重新連線");
				failures = 0;
				this.update({ state: "connected", transport: "polling", error: null });
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
		if (this.liveStream) {
			try {
				this.liveStream.send(JSON.stringify({ type: "report", paths }));
				return; // lastReportAt is set when the server acks
			} catch {
				// the connection is closing: report over HTTP instead
			}
		}
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
			parts.push(
				status.transport === "stream"
					? "已連線（即時推送），等待其他裝置的修改。"
					: status.transport === "polling"
						? "已連線（輪詢），等待其他裝置的修改。"
						: "已連線，等待其他裝置的修改。",
			);
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
