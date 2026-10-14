import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
	CHANGES_PATH,
	CLIENT_HEADER,
	Debouncer,
	IGNORE_AFTER_REMOTE_SYNC_MS,
	LOCAL_REPORT_DEBOUNCE_MS,
	LiveSync,
	PathQueue,
	REMOTELY_SAVE_SYNC_COMMAND,
	REMOTE_SYNC_BUSY_RETRY_MS,
	REMOTE_SYNC_DEBOUNCE_MS,
	SLOW_RETRY_MS,
	changesPath,
	createClientId,
	describeLiveSync,
	hasRemoteChanges,
	isClientId,
	isReportablePath,
	isSlowFailure,
	parseVaultChanges,
	retryDelay,
	startRemotelySaveSync,
	type RemoteSyncResult,
	type VaultChange,
} from "../src/live-sync";
import { ApiError, LocalOcrClient, type HttpFn, type HttpRequest, type JsonRequestOptions } from "../src/sync-core";

const ME = "obsidian-abcdefghijkl";

const change = (seq: number, client: string | null, path: string | null = `${seq}.md`): VaultChange => ({
	seq,
	path,
	op: "write",
	client,
	at: "2026-10-14T08:00:00.000Z",
});

describe("changesPath", () => {
	it("asks for the current cursor first, then long-polls since the cursor", () => {
		expect(changesPath(null)).toBe("/v1/vault/changes");
		expect(changesPath("9f3c2a1b7d4e:42")).toBe("/v1/vault/changes?since=9f3c2a1b7d4e%3A42&wait=25");
		expect(changesPath("e:1", 0)).toBe("/v1/vault/changes?since=e%3A1&wait=0");
	});
});

describe("parseVaultChanges", () => {
	it("accepts the server's shape and skips unknown entries", () => {
		const body = {
			cursor: "e:3",
			reset: false,
			changes: [
				change(1, "ipad"),
				{ seq: 2, path: null, op: "external", client: null, at: "2026-10-14T08:00:01.000Z" },
				{ seq: 3, path: "x.md", op: "rename", client: null, at: "" },
				{ seq: "4", path: "x.md", op: "write", client: null },
				null,
			],
		};
		expect(parseVaultChanges(body)).toEqual({
			cursor: "e:3",
			reset: false,
			changes: [change(1, "ipad"), { seq: 2, path: null, op: "external", client: null, at: "2026-10-14T08:00:01.000Z" }],
		});
	});

	it("rejects anything else with bad_response", () => {
		for (const body of [null, [], { cursor: "", reset: false, changes: [] }, { cursor: "e:1", reset: "no", changes: [] }, { cursor: "e:1", reset: false }]) {
			expect(() => parseVaultChanges(body)).toThrow(ApiError);
		}
	});
});

describe("hasRemoteChanges", () => {
	it("is true for another client's change or a reset, false for only our own", () => {
		expect(hasRemoteChanges({ cursor: "e:1", reset: false, changes: [] }, ME)).toBe(false);
		expect(hasRemoteChanges({ cursor: "e:1", reset: false, changes: [change(1, ME)] }, ME)).toBe(false);
		expect(hasRemoteChanges({ cursor: "e:2", reset: false, changes: [change(1, ME), change(2, "ipad-1")] }, ME)).toBe(true);
		expect(hasRemoteChanges({ cursor: "e:1", reset: false, changes: [change(1, null)] }, ME)).toBe(true);
		expect(hasRemoteChanges({ cursor: "e:9", reset: true, changes: [] }, ME)).toBe(true);
	});
});

describe("retry delays", () => {
	it("backs off 5 s, 15 s, then 60 s", () => {
		const network = new ApiError("無法連線", 0, "network");
		expect([1, 2, 3, 4, 10].map((n) => retryDelay(network, n))).toEqual([5_000, 15_000, 60_000, 60_000, 60_000]);
		expect(retryDelay(new ApiError("伺服器錯誤", 502), 1)).toBe(5_000);
		expect(retryDelay(new Error("boom"), 2)).toBe(15_000);
	});

	it("retries every 10 minutes for an old server, no vault or a bad key", () => {
		for (const error of [
			new ApiError("找不到端點", 404, "not_found"),
			new ApiError("未設定", 503, "vault_not_configured"),
			new ApiError("金鑰", 401, "unauthorized"),
		]) {
			expect(isSlowFailure(error)).toBe(true);
			expect(retryDelay(error, 1)).toBe(SLOW_RETRY_MS);
		}
		expect(isSlowFailure(new ApiError("伺服器錯誤", 503, "internal_error"))).toBe(false);
		expect(SLOW_RETRY_MS).toBe(600_000);
	});
});

describe("client id and paths", () => {
	it("creates obsidian-<12 random characters>", () => {
		const id = createClientId((n) => Uint8Array.from({ length: n }, (_, i) => i * 7));
		expect(id).toBe("obsidian-ahov29gnu18f");
		expect(isClientId(id)).toBe(true);
		const random = createClientId();
		expect(random).toMatch(/^obsidian-[a-z0-9]{12}$/);
		expect(random).not.toBe(createClientId());
		for (const bad of [null, "", "ipad-1234", "obsidian-", "obsidian-ABC12345", 42]) expect(isClientId(bad)).toBe(false);
	});

	it("reports notes and attachments, not the config folder or dot files", () => {
		expect(isReportablePath("Daily/2026-10-14.md", ".obsidian")).toBe(true);
		expect(isReportablePath("_attachments/a.png", ".obsidian")).toBe(true);
		expect(isReportablePath(".obsidian/workspace.json", ".obsidian")).toBe(false);
		expect(isReportablePath(".obsidian", ".obsidian")).toBe(false);
		expect(isReportablePath("config/app.json", "config")).toBe(false);
		expect(isReportablePath(".trash/x.md", ".obsidian")).toBe(false);
		expect(isReportablePath("Notes/.hidden.md", ".obsidian")).toBe(false);
		expect(isReportablePath("", ".obsidian")).toBe(false);
	});

	it("queues paths deduplicated, and more than 100 as 'something changed'", () => {
		const queue = new PathQueue();
		expect(queue.take()).toBeNull();
		queue.add("a.md");
		queue.add("b.md");
		queue.add("a.md");
		expect(queue.take()).toEqual(["a.md", "b.md"]);
		expect(queue.take()).toBeNull();
		for (let i = 0; i < 101; i++) queue.add(`${i}.md`);
		expect(queue.take()).toEqual([]);
	});
});

describe("Debouncer", () => {
	beforeEach(() => vi.useFakeTimers());
	afterEach(() => vi.useRealTimers());

	it("runs once, delayMs after the latest schedule()", () => {
		const run = vi.fn();
		const debouncer = new Debouncer(run, 1000);
		debouncer.schedule();
		vi.advanceTimersByTime(800);
		debouncer.schedule();
		vi.advanceTimersByTime(800);
		expect(run).not.toHaveBeenCalled();
		expect(debouncer.pending).toBe(true);
		vi.advanceTimersByTime(200);
		expect(run).toHaveBeenCalledTimes(1);
		expect(debouncer.pending).toBe(false);

		debouncer.schedule(5000);
		vi.advanceTimersByTime(4999);
		debouncer.cancel();
		vi.advanceTimersByTime(10_000);
		expect(run).toHaveBeenCalledTimes(1);
	});
});

describe("startRemotelySaveSync", () => {
	const enabled = (ids: string[]) => ({ enabledPlugins: new Set(ids) });

	it("is unavailable when Remotely Save is not enabled", async () => {
		const executeCommandById = vi.fn(() => true);
		const app = { plugins: { ...enabled([]), plugins: {} }, commands: { executeCommandById } };
		expect(await startRemotelySaveSync(app)).toBe("unavailable");
		expect(executeCommandById).not.toHaveBeenCalled();
	});

	it("runs the plugin's own quiet auto sync and waits for it", async () => {
		let finish = () => {};
		const syncRun = vi.fn(() => new Promise<void>((resolve) => (finish = resolve)));
		const plugin = { syncStatus: "idle", syncRun };
		const app = { plugins: { ...enabled(["remotely-save"]), plugins: { "remotely-save": plugin } }, commands: {} };
		let result: RemoteSyncResult | null = null;
		const started = startRemotelySaveSync(app).then((r) => (result = r));
		expect(syncRun).toHaveBeenCalledWith("auto");
		expect(syncRun.mock.contexts[0]).toBe(plugin);
		await Promise.resolve();
		expect(result).toBeNull();
		finish();
		await started;
		expect(result).toBe("started");
	});

	it("is busy while Remotely Save is syncing", async () => {
		const syncRun = vi.fn();
		const app = { plugins: { ...enabled(["remotely-save"]), plugins: { "remotely-save": { syncStatus: "syncing", syncRun } } } };
		expect(await startRemotelySaveSync(app)).toBe("busy");
		const newer = { plugins: { ...enabled(["remotely-save"]), plugins: { "remotely-save": { isSyncing: true, syncRun } } } };
		expect(await startRemotelySaveSync(newer)).toBe("busy");
		expect(syncRun).not.toHaveBeenCalled();
	});

	it("falls back to the start-sync command", async () => {
		const commands = { executeCommandById: vi.fn((id: string) => id === "remotely-save:start-sync") };
		expect(REMOTELY_SAVE_SYNC_COMMAND).toBe("remotely-save:start-sync");
		expect(await startRemotelySaveSync({ plugins: { ...enabled(["remotely-save"]) }, commands })).toBe("started");
		expect(commands.executeCommandById).toHaveBeenCalledWith("remotely-save:start-sync");
		expect(commands.executeCommandById.mock.contexts[0]).toBe(commands);
		// unknown command, or nothing to call at all
		expect(await startRemotelySaveSync({ commands: { executeCommandById: () => false } })).toBe("unavailable");
		expect(await startRemotelySaveSync(null)).toBe("unavailable");
	});
});

describe("LocalOcrClient extra headers", () => {
	it("sends X-LocalOCR-Client but never lets extra headers replace its own", async () => {
		const requests: HttpRequest[] = [];
		const http: HttpFn = async (req) => {
			requests.push(req);
			return { status: 202, text: JSON.stringify({ cursor: "e:1" }) };
		};
		const client = new LocalOcrClient("https://ocr.example.com", "secret-key-123", http);
		await client.requestJson(CHANGES_PATH, {
			method: "POST",
			body: { paths: ["a.md"] },
			headers: { [CLIENT_HEADER]: ME, authorization: "Bearer stolen", ACCEPT: "text/html" },
		});
		expect(requests[0].headers).toEqual({
			[CLIENT_HEADER]: ME,
			Accept: "application/json",
			Authorization: "Bearer secret-key-123",
			"Content-Type": "application/json",
		});
		expect(requests[0].body).toBe('{"paths":["a.md"]}');
	});
});

describe("LiveSync", () => {
	interface Call {
		path: string;
		options: JsonRequestOptions;
		resolve: (body: unknown) => void;
		reject: (error: unknown) => void;
	}

	beforeEach(() => vi.useFakeTimers());
	afterEach(() => vi.useRealTimers());

	/** A server whose answers the test gives by hand. */
	function harness(syncResult: () => Promise<RemoteSyncResult> = async () => "started") {
		const calls: Call[] = [];
		const client = {
			requestJson: (path: string, options: JsonRequestOptions = {}) =>
				new Promise<unknown>((resolve, reject) => calls.push({ path, options, resolve, reject })),
		};
		const syncRemote = vi.fn(syncResult);
		const log = vi.fn();
		const live = new LiveSync({ client, clientId: ME, configDir: ".obsidian", syncRemote, log });
		const polls = () => calls.filter((call) => (call.options.method ?? "GET") === "GET");
		const reports = () => calls.filter((call) => call.options.method === "POST");
		const lastPoll = () => polls()[polls().length - 1];
		const flush = () => vi.advanceTimersByTimeAsync(0);
		/** Answers the latest poll, then lets the 1 s minimum interval pass. */
		const answer = async (body: unknown) => {
			lastPoll().resolve(body);
			await vi.advanceTimersByTimeAsync(1000);
		};
		return { live, calls, polls, reports, lastPoll, syncRemote, log, flush, answer };
	}

	it("gets a cursor, then long-polls with it and the client header", async () => {
		const h = harness();
		h.live.start();
		expect(h.live.status.state).toBe("connecting");
		expect(h.polls()).toHaveLength(1);
		expect(h.lastPoll().path).toBe("/v1/vault/changes");
		expect(h.lastPoll().options.headers).toEqual({ [CLIENT_HEADER]: ME });

		await h.answer({ cursor: "e:5", reset: false, changes: [] });
		expect(h.live.status.state).toBe("connected");
		expect(h.polls()).toHaveLength(2);
		expect(h.lastPoll().path).toBe("/v1/vault/changes?since=e%3A5&wait=25");

		await h.answer({ cursor: "e:6", reset: false, changes: [change(6, ME)] }); // our own change only
		expect(h.lastPoll().path).toBe("/v1/vault/changes?since=e%3A6&wait=25");
		await vi.advanceTimersByTimeAsync(5000);
		expect(h.syncRemote).not.toHaveBeenCalled();
		h.live.stop();
	});

	it("runs Remotely Save 1 s after another device's changes (debounced) and on reset", async () => {
		const h = harness();
		h.live.start();
		await h.answer({ cursor: "e:0", reset: false, changes: [] });
		h.lastPoll().resolve({ cursor: "e:1", reset: false, changes: [change(1, "ipad-1")] });
		await h.flush();
		await vi.advanceTimersByTimeAsync(REMOTE_SYNC_DEBOUNCE_MS - 1);
		expect(h.syncRemote).not.toHaveBeenCalled();
		h.lastPoll().resolve({ cursor: "e:2", reset: false, changes: [change(2, "mcp")] }); // within the debounce
		await vi.advanceTimersByTimeAsync(REMOTE_SYNC_DEBOUNCE_MS);
		expect(h.syncRemote).toHaveBeenCalledTimes(1);
		expect(h.live.status.lastRemoteChangeAt).not.toBeNull();

		await vi.advanceTimersByTimeAsync(1000);
		h.lastPoll().resolve({ cursor: "f:0", reset: true, changes: [] }); // the server restarted
		await vi.advanceTimersByTimeAsync(REMOTE_SYNC_DEBOUNCE_MS);
		expect(h.syncRemote).toHaveBeenCalledTimes(2);
		expect(h.lastPoll().path).toBe("/v1/vault/changes?since=f%3A0&wait=25");
		h.live.stop();
	});

	it("never syncs for the first (cursor-only) answer", async () => {
		const h = harness();
		h.live.start();
		await h.answer({ cursor: "e:9", reset: true, changes: [change(9, "ipad-1")] });
		await vi.advanceTimersByTimeAsync(5000);
		expect(h.syncRemote).not.toHaveBeenCalled();
		h.live.stop();
	});

	it("backs off 5 s, 15 s, 60 s on failures and keeps its cursor", async () => {
		const h = harness();
		h.live.start();
		await h.answer({ cursor: "e:3", reset: false, changes: [] });
		const network = new ApiError("無法連線到伺服器：offline", 0, "network");

		h.lastPoll().reject(network);
		await h.flush();
		expect(h.live.status).toMatchObject({ state: "retrying", error: "無法連線到伺服器：offline" });
		expect(h.log).toHaveBeenCalledTimes(1);
		for (const delay of [5_000, 15_000, 60_000, 60_000]) {
			const count = h.polls().length;
			await vi.advanceTimersByTimeAsync(delay - 1);
			expect(h.polls()).toHaveLength(count);
			await vi.advanceTimersByTimeAsync(1);
			expect(h.polls()).toHaveLength(count + 1);
			expect(h.lastPoll().path).toBe("/v1/vault/changes?since=e%3A3&wait=25");
			h.lastPoll().reject(network);
			await h.flush();
		}
		expect(h.log).toHaveBeenCalledTimes(1); // only the first failure of a streak is logged

		await vi.advanceTimersByTimeAsync(60_000);
		await h.answer({ cursor: "e:3", reset: false, changes: [] });
		expect(h.live.status).toMatchObject({ state: "connected", error: null });
		h.live.stop();
	});

	it("waits 10 minutes when the server has no change feed (404) and sends no reports meanwhile", async () => {
		const h = harness();
		h.live.start();
		h.lastPoll().reject(new ApiError("找不到端點，請確認伺服器網址（404）", 404, "not_found"));
		await h.flush();
		expect(h.live.status.state).toBe("unsupported");
		h.live.noteLocalChange(["a.md"]);
		await vi.advanceTimersByTimeAsync(LOCAL_REPORT_DEBOUNCE_MS);
		expect(h.reports()).toHaveLength(0);

		await vi.advanceTimersByTimeAsync(SLOW_RETRY_MS - LOCAL_REPORT_DEBOUNCE_MS - 1);
		expect(h.polls()).toHaveLength(1);
		await vi.advanceTimersByTimeAsync(1);
		expect(h.polls()).toHaveLength(2);
		h.live.stop();
	});

	it("stops cleanly and ignores a poll that answers after stop()", async () => {
		const h = harness();
		h.live.start();
		await h.answer({ cursor: "e:0", reset: false, changes: [] });
		const inFlight = h.lastPoll();
		h.live.stop();
		expect(h.live.status.state).toBe("stopped");
		inFlight.resolve({ cursor: "e:1", reset: false, changes: [change(1, "ipad-1")] });
		await vi.advanceTimersByTimeAsync(120_000);
		expect(h.syncRemote).not.toHaveBeenCalled();
		expect(h.polls()).toHaveLength(2);

		// a stop during a retry wait ends the wait
		const again = harness();
		again.live.start();
		again.lastPoll().reject(new ApiError("x", 0, "network"));
		await again.flush();
		again.live.stop();
		await vi.advanceTimersByTimeAsync(120_000);
		expect(again.polls()).toHaveLength(1);
		expect(vi.getTimerCount()).toBe(0);
	});

	it("reports local edits 8 s after the last one, deduplicated and filtered", async () => {
		const h = harness();
		h.live.start();
		await h.answer({ cursor: "e:0", reset: false, changes: [] });
		h.live.noteLocalChange(["Daily/2026-10-14.md"]);
		await vi.advanceTimersByTimeAsync(5000);
		h.live.noteLocalChange([".obsidian/workspace.json"]);
		h.live.noteLocalChange(["Inbox/舊.md", "Inbox/新.md"]); // a rename
		h.live.noteLocalChange(["Daily/2026-10-14.md"]);
		await vi.advanceTimersByTimeAsync(LOCAL_REPORT_DEBOUNCE_MS - 1);
		expect(h.reports()).toHaveLength(0);
		await vi.advanceTimersByTimeAsync(1);
		expect(h.reports()).toHaveLength(1);
		const [report] = h.reports();
		expect(report.path).toBe("/v1/vault/changes");
		expect(report.options.body).toEqual({ paths: ["Daily/2026-10-14.md", "Inbox/舊.md", "Inbox/新.md"] });
		expect(report.options.headers).toEqual({ [CLIENT_HEADER]: ME });
		report.resolve({ cursor: "e:3" });
		await h.flush();
		expect(h.live.status.lastReportAt).not.toBeNull();

		// only ignored paths: nothing is sent
		h.live.noteLocalChange([".obsidian/app.json", ".trash/x.md"]);
		await vi.advanceTimersByTimeAsync(LOCAL_REPORT_DEBOUNCE_MS);
		expect(h.reports()).toHaveLength(1);

		// a failed report is only logged
		h.live.noteLocalChange(["x.md"]);
		await vi.advanceTimersByTimeAsync(LOCAL_REPORT_DEBOUNCE_MS);
		h.reports()[1].reject(new ApiError("伺服器錯誤（502）", 502));
		await h.flush();
		expect(h.log).toHaveBeenCalledWith(expect.stringContaining("無法通知其他裝置"));
		h.live.stop();
	});

	it("ignores vault events for 20 s after it started Remotely Save (its downloads)", async () => {
		let finishSync: (result: RemoteSyncResult) => void = () => {};
		const h = harness(() => new Promise<RemoteSyncResult>((resolve) => (finishSync = resolve)));
		h.live.start();
		await h.answer({ cursor: "e:0", reset: false, changes: [] });
		h.lastPoll().resolve({ cursor: "e:1", reset: false, changes: [change(1, "ipad-1")] });
		await vi.advanceTimersByTimeAsync(REMOTE_SYNC_DEBOUNCE_MS);
		expect(h.syncRemote).toHaveBeenCalledTimes(1);

		h.live.noteLocalChange(["1.md"]); // downloaded by that sync
		await vi.advanceTimersByTimeAsync(3000);
		finishSync("started");
		await h.flush();
		h.live.noteLocalChange(["1.md"]);
		await vi.advanceTimersByTimeAsync(IGNORE_AFTER_REMOTE_SYNC_MS - 3000 - 1);
		h.live.noteLocalChange(["1.md"]);
		await vi.advanceTimersByTimeAsync(LOCAL_REPORT_DEBOUNCE_MS + 1);
		expect(h.reports()).toHaveLength(0);

		h.live.noteLocalChange(["mine.md"]); // a real edit after the window
		await vi.advanceTimersByTimeAsync(LOCAL_REPORT_DEBOUNCE_MS);
		expect(h.reports().map((r) => r.options.body)).toEqual([{ paths: ["mine.md"] }]);
		h.live.stop();
	});

	it("retries while Remotely Save is busy, without ignoring local edits", async () => {
		const results: RemoteSyncResult[] = ["busy", "busy", "started"];
		const h = harness(async () => results.shift() ?? "started");
		h.live.start();
		await h.answer({ cursor: "e:0", reset: false, changes: [] });
		h.lastPoll().resolve({ cursor: "e:1", reset: false, changes: [change(1, "ipad-1")] });
		await vi.advanceTimersByTimeAsync(REMOTE_SYNC_DEBOUNCE_MS);
		expect(h.syncRemote).toHaveBeenCalledTimes(1);

		h.live.noteLocalChange(["mine.md"]); // not ignored: the busy attempt downloaded nothing
		await vi.advanceTimersByTimeAsync(REMOTE_SYNC_BUSY_RETRY_MS);
		expect(h.syncRemote).toHaveBeenCalledTimes(2);
		await vi.advanceTimersByTimeAsync(REMOTE_SYNC_BUSY_RETRY_MS);
		expect(h.syncRemote).toHaveBeenCalledTimes(3);
		await vi.advanceTimersByTimeAsync(REMOTE_SYNC_BUSY_RETRY_MS * 3);
		expect(h.syncRemote).toHaveBeenCalledTimes(3);
		expect(h.reports().map((r) => r.options.body)).toEqual([{ paths: ["mine.md"] }]);
		h.live.stop();
	});

	it("runs once more when changes arrive during a Remotely Save sync, and notes a missing Remotely Save", async () => {
		const finishers: ((result: RemoteSyncResult) => void)[] = [];
		const h = harness(() => new Promise<RemoteSyncResult>((resolve) => finishers.push(resolve)));
		h.live.start();
		await h.answer({ cursor: "e:0", reset: false, changes: [] });
		h.lastPoll().resolve({ cursor: "e:1", reset: false, changes: [change(1, "ipad-1")] });
		await vi.advanceTimersByTimeAsync(REMOTE_SYNC_DEBOUNCE_MS + 1000);
		h.lastPoll().resolve({ cursor: "e:2", reset: false, changes: [change(2, "ipad-1")] });
		await vi.advanceTimersByTimeAsync(REMOTE_SYNC_DEBOUNCE_MS);
		expect(h.syncRemote).toHaveBeenCalledTimes(1); // the first sync is still running
		finishers[0]("started");
		await h.flush();
		await vi.advanceTimersByTimeAsync(REMOTE_SYNC_DEBOUNCE_MS);
		expect(h.syncRemote).toHaveBeenCalledTimes(2);
		finishers[1]("unavailable");
		await h.flush();
		expect(h.live.status.remotelySaveUnavailable).toBe(true);
		h.live.stop();
	});
});

describe("describeLiveSync", () => {
	const base = { lastRemoteChangeAt: null, lastReportAt: null, error: null, remotelySaveUnavailable: false };
	const time = (ms: number) => `t${ms}`;

	it("describes each state in Traditional Chinese", () => {
		expect(describeLiveSync({ ...base, state: "stopped" }, time)).toBe("未啟動。");
		expect(describeLiveSync({ ...base, state: "connecting" }, time)).toBe("連線中…");
		expect(describeLiveSync({ ...base, state: "connected", lastRemoteChangeAt: 1, lastReportAt: 2 }, time)).toBe(
			"已連線，等待其他裝置的修改。上次收到其他裝置的修改：t1。上次通知其他裝置：t2。",
		);
		expect(describeLiveSync({ ...base, state: "retrying", error: "逾時" }, time)).toBe("連線中斷，稍後自動重試（逾時）。");
		expect(describeLiveSync({ ...base, state: "unsupported", error: "404" }, time)).toContain("10 分鐘後再試");
		expect(describeLiveSync({ ...base, state: "connected", remotelySaveUnavailable: true }, time)).toContain("尚未啟用 Remotely Save");
	});
});
