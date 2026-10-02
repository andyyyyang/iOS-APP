import { describe, expect, it } from "vitest";
import {
	ApiError,
	EPOCH,
	LocalOcrClient,
	SyncAbortedError,
	advanceCursor,
	initialCursorState,
	lastUpdatedAt,
	nextScanQuery,
	normalizeServerUrl,
	runSync,
	summarize,
	type HttpFn,
	type HttpRequest,
	type ScanQuery,
	type SyncDeps,
} from "../src/sync-core";
import type { Scan, ScanPage, SyncCursorState, Template, WriteOutcome } from "../src/types";

const KEY = "secret-key-123";

function scan(n: number, updatedAt?: string): Scan {
	return {
		id: `scan-${n}`,
		createdAt: `2026-10-01T00:00:${String(n % 60).padStart(2, "0")}.000Z`,
		updatedAt: updatedAt ?? new Date(Date.UTC(2026, 9, 2, 0, 0, n)).toISOString(),
		text: `text ${n}`,
		templateId: "receipt",
		data: { title: `Scan ${n}` },
	};
}

function jsonResponse(status: number, body: unknown) {
	return { status, text: JSON.stringify(body) };
}

describe("normalizeServerUrl", () => {
	it("trims whitespace and trailing slashes", () => {
		expect(normalizeServerUrl("  https://xxx.up.railway.app///  ")).toBe("https://xxx.up.railway.app");
	});
	it("adds https:// when no scheme is given", () => {
		expect(normalizeServerUrl("xxx.up.railway.app/")).toBe("https://xxx.up.railway.app");
		expect(normalizeServerUrl("http://localhost:3000")).toBe("http://localhost:3000");
		expect(normalizeServerUrl("   ")).toBe("");
	});
});

describe("LocalOcrClient", () => {
	function recordingHttp(responder: (req: HttpRequest) => { status: number; text: string }) {
		const requests: HttpRequest[] = [];
		const http: HttpFn = async (req) => {
			requests.push(req);
			return responder(req);
		};
		return { http, requests };
	}

	it("calls /health without and /v1 endpoints with the bearer token", async () => {
		const { http, requests } = recordingHttp((req) =>
			req.url.endsWith("/health")
				? jsonResponse(200, { status: "ok", version: "1.0.0", database: "postgres", jev: true })
				: jsonResponse(200, { items: [{ id: "receipt", name: "收據／發票" }, { bogus: true }] }),
		);
		const client = new LocalOcrClient("https://example.com/", KEY, http);
		expect(await client.health()).toMatchObject({ status: "ok", version: "1.0.0" });
		expect(await client.listTemplates()).toEqual([{ id: "receipt", name: "收據／發票" }]);
		expect(requests[0].url).toBe("https://example.com/health");
		expect(requests[0].headers.Authorization).toBeUndefined();
		expect(requests[1].url).toBe("https://example.com/v1/templates");
		expect(requests[1].headers.Authorization).toBe(`Bearer ${KEY}`);
	});

	it("builds the scans query and normalizes nextCursor", async () => {
		const { http, requests } = recordingHttp(() => jsonResponse(200, { items: [scan(1)], nextCursor: "" }));
		const client = new LocalOcrClient("https://example.com", KEY, http);
		const page = await client.listScans({ limit: 100, updatedAfter: "2026-10-02T03:10:02.000Z", cursor: "a+b/c=" });
		expect(requests[0].url).toBe(
			"https://example.com/v1/scans?limit=100&updatedAfter=2026-10-02T03%3A10%3A02.000Z&cursor=a%2Bb%2Fc%3D",
		);
		expect(page.nextCursor).toBeNull();
		expect(page.items).toHaveLength(1);
		await client.listScans({ limit: 5 });
		expect(requests[1].url).toBe("https://example.com/v1/scans?limit=5");
	});

	it("maps error envelopes to ApiError without leaking the key", async () => {
		const { http } = recordingHttp(() =>
			jsonResponse(401, { error: { code: "unauthorized", message: "Invalid API key" } }),
		);
		const client = new LocalOcrClient("https://example.com", KEY, http);
		const error = await client.listTemplates().catch((e: unknown) => e);
		expect(error).toBeInstanceOf(ApiError);
		expect((error as ApiError).status).toBe(401);
		expect((error as ApiError).code).toBe("unauthorized");
		expect((error as ApiError).isAuthError).toBe(true);
		expect((error as ApiError).message).toContain("API 金鑰無效");
		expect((error as ApiError).message).toContain("Invalid API key");
		expect((error as ApiError).message).not.toContain(KEY);
	});

	it("reports network failures, bad JSON, bad shapes and timeouts", async () => {
		const failing = new LocalOcrClient("https://example.com", KEY, async () => {
			throw new Error("net::ERR_NAME_NOT_RESOLVED");
		});
		await expect(failing.health()).rejects.toMatchObject({ code: "network", status: 0 });

		const html = new LocalOcrClient("https://example.com", KEY, async () => ({ status: 200, text: "<html>" }));
		await expect(html.listTemplates()).rejects.toMatchObject({ code: "bad_response" });

		const shape = new LocalOcrClient("https://example.com", KEY, async () => jsonResponse(200, { nope: [] }));
		await expect(shape.listScans({ limit: 1 })).rejects.toMatchObject({ code: "bad_response" });

		const server500 = new LocalOcrClient("https://example.com", KEY, async () => ({ status: 502, text: "Bad gateway" }));
		await expect(server500.listTemplates()).rejects.toMatchObject({ status: 502 });

		const slow = new LocalOcrClient("https://example.com", KEY, () => new Promise(() => undefined), 20);
		await expect(slow.health()).rejects.toMatchObject({ code: "timeout" });
	});

	it("refuses to call without configuration", async () => {
		const http: HttpFn = async () => jsonResponse(200, {});
		await expect(new LocalOcrClient("", KEY, http).health()).rejects.toMatchObject({ code: "config" });
		await expect(new LocalOcrClient("https://x", "", http).listTemplates()).rejects.toMatchObject({ code: "config" });
	});
});

describe("cursor bookkeeping", () => {
	it("starts with updatedAfter=EPOCH so the server sorts ascending", () => {
		expect(nextScanQuery(initialCursorState())).toEqual({ limit: 100, updatedAfter: EPOCH });
	});

	it("sends the saved cursor together with the saved updatedAfter", () => {
		const state: SyncCursorState = { cursor: "c1", updatedAfter: "2026-10-01T00:00:00.000Z", lastSeenUpdatedAt: null };
		expect(nextScanQuery(state, 50)).toEqual({ limit: 50, updatedAfter: "2026-10-01T00:00:00.000Z", cursor: "c1" });
	});

	it("follows nextCursor and keeps updatedAfter fixed while paging", () => {
		const page: ScanPage = { items: [scan(1), scan(2)], nextCursor: "c2" };
		const { state, done } = advanceCursor(initialCursorState(), page);
		expect(done).toBe(false);
		expect(state).toEqual({ cursor: "c2", updatedAfter: null, lastSeenUpdatedAt: scan(2).updatedAt });
	});

	it("on a null cursor remembers the last updatedAt and clears the cursor", () => {
		const start: SyncCursorState = { cursor: "c2", updatedAfter: null, lastSeenUpdatedAt: scan(2).updatedAt };
		const { state, done } = advanceCursor(start, { items: [scan(3)], nextCursor: null });
		expect(done).toBe(true);
		expect(state).toEqual({ cursor: null, updatedAfter: scan(3).updatedAt, lastSeenUpdatedAt: scan(3).updatedAt });
	});

	it("uses the last item seen on earlier pages when the final page is empty", () => {
		const start: SyncCursorState = { cursor: "c2", updatedAfter: null, lastSeenUpdatedAt: scan(2).updatedAt };
		const { state } = advanceCursor(start, { items: [], nextCursor: null });
		expect(state).toEqual({ cursor: null, updatedAfter: scan(2).updatedAt, lastSeenUpdatedAt: scan(2).updatedAt });
	});

	it("keeps updatedAfter when nothing has ever been seen", () => {
		const start: SyncCursorState = { cursor: null, updatedAfter: "2026-01-01T00:00:00.000Z", lastSeenUpdatedAt: null };
		expect(advanceCursor(start, { items: [], nextCursor: null }).state.updatedAfter).toBe("2026-01-01T00:00:00.000Z");
	});

	it("stops on an empty page or a repeated cursor but keeps the cursor", () => {
		const start: SyncCursorState = { cursor: "c9", updatedAfter: null, lastSeenUpdatedAt: null };
		expect(advanceCursor(start, { items: [], nextCursor: "c10" })).toEqual({
			state: { cursor: "c10", updatedAfter: null, lastSeenUpdatedAt: null },
			done: true,
		});
		expect(advanceCursor(start, { items: [scan(1)], nextCursor: "c9" }).done).toBe(true);
	});

	it("finds the last valid updatedAt", () => {
		expect(lastUpdatedAt([scan(1), { id: "x" } as Scan])).toBe(scan(1).updatedAt);
		expect(lastUpdatedAt([])).toBeNull();
	});
});

/**
 * In-memory server mimicking GET /v1/scans incremental mode: ascending by
 * updatedAt, `updatedAfter` exclusive, opaque cursor = position after an item.
 */
class FakeServer {
	scans: Scan[] = [];
	queries: ScanQuery[] = [];
	templateCalls = 0;
	failOnCall: number | null = null;
	/** When true, behave like a server that always returns a resume cursor. */
	alwaysCursor = false;

	constructor(count: number) {
		for (let i = 1; i <= count; i++) this.scans.push(scan(i));
	}

	client(): SyncDeps["client"] {
		return {
			listTemplates: async (): Promise<Template[]> => {
				this.templateCalls++;
				return [{ id: "receipt", name: "收據／發票" }];
			},
			listScans: async (query: ScanQuery): Promise<ScanPage> => {
				this.queries.push(query);
				if (this.failOnCall === this.queries.length) throw new ApiError("伺服器錯誤（503）", 503);
				const sorted = [...this.scans].sort((a, b) => a.updatedAt.localeCompare(b.updatedAt) || a.id.localeCompare(b.id));
				let start = 0;
				if (query.cursor) {
					const [updatedAt, id] = JSON.parse(Buffer.from(query.cursor, "base64").toString()) as [string, string];
					start = sorted.findIndex((s) => s.updatedAt > updatedAt || (s.updatedAt === updatedAt && s.id > id));
					if (start < 0) start = sorted.length;
				} else if (query.updatedAfter) {
					start = sorted.findIndex((s) => s.updatedAt > query.updatedAfter!);
					if (start < 0) start = sorted.length;
				}
				const items = sorted.slice(start, start + query.limit);
				const hasMore = start + query.limit < sorted.length;
				const last = items[items.length - 1];
				const cursorFor = (s: Scan) => Buffer.from(JSON.stringify([s.updatedAt, s.id])).toString("base64");
				let nextCursor: string | null = null;
				if (this.alwaysCursor) nextCursor = last ? cursorFor(last) : query.cursor ?? null;
				else if (hasMore && last) nextCursor = cursorFor(last);
				return { items, nextCursor };
			},
		};
	}
}

function harness(server: FakeServer, initial: SyncCursorState = initialCursorState()) {
	const notes = new Map<string, Scan>();
	const saved: SyncCursorState[] = [];
	let state = initial;
	const deps = (): SyncDeps => ({
		client: server.client(),
		state,
		pageSize: 10,
		writeScan: async (s: Scan, templates): Promise<WriteOutcome> => {
			expect(templates.get("receipt")).toBe("收據／發票");
			const previous = notes.get(s.id);
			notes.set(s.id, s);
			if (!previous) return "created";
			return previous.updatedAt === s.updatedAt ? "unchanged" : "updated";
		},
		saveState: async (next) => {
			state = next;
			saved.push(next);
		},
	});
	return { notes, saved, deps, getState: () => state };
}

describe("runSync", () => {
	it("pages through everything and saves progress after every page", async () => {
		const server = new FakeServer(25);
		const h = harness(server);
		const result = await runSync(h.deps());
		expect(result).toMatchObject({ created: 25, updated: 0, unchanged: 0, failed: 0, pages: 3 });
		expect(h.notes.size).toBe(25);
		expect(h.saved).toHaveLength(3);
		expect(server.queries[0]).toEqual({ limit: 10, updatedAfter: EPOCH });
		expect(server.queries[1].cursor).toBeTruthy();
		expect(h.getState()).toEqual({
			cursor: null,
			updatedAfter: scan(25).updatedAt,
			lastSeenUpdatedAt: scan(25).updatedAt,
		});
		expect(server.templateCalls).toBe(1);
	});

	it("only fetches changes on the next run", async () => {
		const server = new FakeServer(5);
		const h = harness(server);
		await runSync(h.deps());
		server.queries = [];

		server.scans[1] = { ...server.scans[1], updatedAt: "2026-10-03T00:00:00.000Z", data: { title: "edited" } };
		server.scans.push(scan(6, "2026-10-03T00:00:01.000Z"));
		const result = await runSync(h.deps());
		expect(result).toMatchObject({ created: 1, updated: 1, unchanged: 0 });
		expect(server.queries[0]).toEqual({ limit: 10, updatedAfter: scan(5).updatedAt });

		const idle = await runSync(h.deps());
		expect(idle).toMatchObject({ created: 0, updated: 0, pages: 1 });
	});

	it("resumes from the saved cursor after an interruption", async () => {
		const server = new FakeServer(25);
		server.failOnCall = 2;
		const h = harness(server);
		const error = await runSync(h.deps()).catch((e: unknown) => e);
		expect(error).toBeInstanceOf(SyncAbortedError);
		expect((error as SyncAbortedError).result.created).toBe(10);
		expect((error as SyncAbortedError).message).toContain("503");
		expect(h.getState().cursor).toBeTruthy();

		server.failOnCall = null;
		server.queries = [];
		const result = await runSync(h.deps());
		expect(result.created).toBe(15); // page 1 is not fetched again
		expect(server.queries[0].cursor).toBe(h.saved[0].cursor);
		expect(server.queries[0].updatedAfter).toBe(EPOCH);
		expect(h.notes.size).toBe(25);
		expect(h.getState().cursor).toBeNull();
	});

	it("works with servers that always return a resume cursor", async () => {
		const server = new FakeServer(12);
		server.alwaysCursor = true;
		const h = harness(server);
		const first = await runSync(h.deps());
		expect(first.created).toBe(12);
		expect(first.pages).toBe(3); // 10 + 2 + empty page
		const cursor = h.getState().cursor;
		expect(cursor).toBeTruthy();

		server.scans.push(scan(13, "2026-10-04T00:00:00.000Z"));
		server.queries = [];
		const second = await runSync(h.deps());
		expect(second.created).toBe(1);
		expect(server.queries[0].cursor).toBe(cursor);
	});

	it("re-downloads everything after a reset without duplicating notes", async () => {
		const server = new FakeServer(3);
		const h = harness(server);
		await runSync(h.deps());
		const result = await runSync({ ...h.deps(), state: initialCursorState() });
		expect(result).toMatchObject({ created: 0, unchanged: 3 });
		expect(h.notes.size).toBe(3);
	});

	it("counts failed writes and invalid items but keeps going", async () => {
		const server = new FakeServer(3);
		server.scans.push({ id: "", updatedAt: "2026-10-02T00:00:59.000Z" } as Scan);
		const h = harness(server);
		const deps = h.deps();
		const result = await runSync({
			...deps,
			writeScan: async (s, t) => {
				if (s.id === "scan-2") throw new Error("disk full");
				return deps.writeScan(s, t);
			},
		});
		expect(result).toMatchObject({ created: 2, failed: 2 });
		expect(result.errors).toContain("scan-2：disk full");
		expect(h.getState().updatedAfter).toBe("2026-10-02T00:00:59.000Z");
	});

	it("aborts when templates cannot be loaded, without saving state", async () => {
		const h = harness(new FakeServer(1));
		const deps = h.deps();
		await expect(
			runSync({
				...deps,
				client: {
					...deps.client,
					listTemplates: async () => {
						throw new ApiError("API 金鑰無效或未提供（401）", 401);
					},
				},
			}),
		).rejects.toBeInstanceOf(SyncAbortedError);
		expect(h.saved).toHaveLength(0);
	});

	it("stops when cancelled", async () => {
		const server = new FakeServer(25);
		const h = harness(server);
		let writes = 0;
		const deps = h.deps();
		const result = await runSync({
			...deps,
			writeScan: async (s, t) => {
				writes++;
				return deps.writeScan(s, t);
			},
			isCancelled: () => writes >= 15,
		});
		expect(writes).toBe(15);
		expect(result.created).toBe(15);
		expect(h.saved).toHaveLength(1); // the half-written second page is fetched again next time
	});

	it("respects maxPages", async () => {
		const server = new FakeServer(50);
		const h = harness(server);
		const result = await runSync({ ...h.deps(), maxPages: 2 });
		expect(result.created).toBe(20);
		expect(h.getState().cursor).toBeTruthy();
	});
});

describe("summarize", () => {
	it("formats counts", () => {
		expect(summarize({ created: 3, updated: 1, unchanged: 0, failed: 0, pages: 1, errors: [] })).toBe(
			"新增 3 筆、更新 1 筆",
		);
		expect(summarize({ created: 0, updated: 0, unchanged: 2, failed: 1, pages: 1, errors: [] })).toBe(
			"新增 0 筆、更新 0 筆、未變更 2 筆、失敗 1 筆",
		);
	});
});
