import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { Express } from "express";
import request from "supertest";
import { afterEach, describe, expect, it, vi } from "vitest";
import { VaultChangeFeed, type VaultChangeInput } from "../src/services/vault-changes.js";
import { MemoryVaultStore } from "../src/vault/index.js";
import { AUTH, setup } from "./helpers.js";

const CLIENT = "X-LocalOCR-Client";
const NOW = Date.parse("2026-10-14T08:00:00.000Z");

const write = (path: string, client: string | null = null): VaultChangeInput => ({ path, op: "write", client });

describe("VaultChangeFeed", () => {
  const feed = (options: ConstructorParameters<typeof VaultChangeFeed>[0] = {}) =>
    new VaultChangeFeed({ epoch: "e1", now: () => NOW, ...options });

  it("answers the current cursor right away without since", async () => {
    const changes = feed();
    expect(await changes.poll({ client: null, waitMs: 5000 })).toEqual({ cursor: "e1:0", reset: false, changes: [] });
    changes.record([write("a.md"), write("b.md")]);
    expect(await changes.poll({ since: "", client: "x", waitMs: 5000 })).toEqual({ cursor: "e1:2", reset: false, changes: [] });
    expect(changes.waiting).toBe(0);
  });

  it("generates a random epoch without colons", () => {
    const a = new VaultChangeFeed();
    const b = new VaultChangeFeed();
    expect(a.epoch).toMatch(/^[0-9a-f]{12}$/);
    expect(a.epoch).not.toBe(b.epoch);
    expect(a.cursor).toBe(`${a.epoch}:0`);
  });

  it("lists changes after since with seq, path, op, client and time", async () => {
    const changes = feed();
    expect(changes.record([write("a.md", "ipad"), { path: "b.md", op: "delete", client: null }])).toBe("e1:2");
    changes.record([{ path: null, op: "external", client: "obsidian-1" }]);
    expect(await changes.poll({ since: "e1:0", client: null, waitMs: 0 })).toEqual({
      cursor: "e1:3",
      reset: false,
      changes: [
        { seq: 1, path: "a.md", op: "write", client: "ipad", at: "2026-10-14T08:00:00.000Z" },
        { seq: 2, path: "b.md", op: "delete", client: null, at: "2026-10-14T08:00:00.000Z" },
        { seq: 3, path: null, op: "external", client: "obsidian-1", at: "2026-10-14T08:00:00.000Z" },
      ],
    });
    expect((await changes.poll({ since: "e1:2", client: null, waitMs: 0 })).changes.map((c) => c.seq)).toEqual([3]);
    expect(await changes.poll({ since: "e1:3", client: null, waitMs: 0 })).toEqual({ cursor: "e1:3", reset: false, changes: [] });
  });

  it("leaves out the requester's own changes but still advances its cursor", async () => {
    const changes = feed();
    changes.record([write("mine.md", "ipad"), write("mcp.md", "mcp"), write("unknown.md", null), write("again.md", "ipad")]);
    const others = await changes.poll({ since: "e1:0", client: "ipad", waitMs: 0 });
    expect(others.cursor).toBe("e1:4");
    expect(others.changes.map((c) => c.path)).toEqual(["mcp.md", "unknown.md"]);

    changes.record([write("mine2.md", "ipad")]);
    expect(await changes.poll({ since: "e1:4", client: "ipad", waitMs: 0 })).toEqual({ cursor: "e1:5", reset: false, changes: [] });
    // without a client id nothing is left out
    expect((await changes.poll({ since: "e1:4", client: null, waitMs: 0 })).changes.map((c) => c.path)).toEqual(["mine2.md"]);
  });

  it("answers reset for malformed, foreign, future and dropped cursors", async () => {
    const changes = feed({ capacity: 3 });
    for (const path of ["1.md", "2.md", "3.md", "4.md", "5.md"]) changes.record([write(path)]);
    const reset = { cursor: "e1:5", reset: true, changes: [] };
    for (const since of ["garbage", "e1", "e1:", "e1:-1", "e1:1.5", "e1:abc", "e2:5", ":5", "e1:6", ["e1:4", "e1:5"]]) {
      expect(await changes.poll({ since, client: null, waitMs: 5000 }), JSON.stringify(since)).toEqual(reset);
    }
    // seqs 3–5 are kept: a cursor at 2 still sees all of them, one at 1 has missed seq 2
    expect((await changes.poll({ since: "e1:2", client: null, waitMs: 0 })).changes.map((c) => c.seq)).toEqual([3, 4, 5]);
    expect(await changes.poll({ since: "e1:1", client: null, waitMs: 0 })).toEqual(reset);
    expect(await changes.poll({ since: "e1:0", client: null, waitMs: 0 })).toEqual(reset);
    expect(changes.waiting).toBe(0);
  });

  it("answers reset instead of more than maxResponse changes", async () => {
    const changes = feed({ maxResponse: 2 });
    changes.record([write("a.md"), write("b.md"), write("mine.md", "me")]);
    expect((await changes.poll({ since: "e1:0", client: "me", waitMs: 0 })).changes).toHaveLength(2);
    expect(await changes.poll({ since: "e1:0", client: null, waitMs: 0 })).toEqual({ cursor: "e1:3", reset: true, changes: [] });
  });

  it("holds a poll until another client's change arrives", async () => {
    vi.useFakeTimers();
    try {
      const changes = feed();
      let answered: unknown = null;
      const poll = changes.poll({ since: "e1:0", client: "obsidian", waitMs: 25_000 }).then((r) => (answered = r));
      expect(changes.waiting).toBe(1);

      changes.record([write("own.md", "obsidian")]); // its own change does not wake it
      await vi.advanceTimersByTimeAsync(1000);
      expect(answered).toBeNull();

      changes.record([write("ipad.md", "ipad")]);
      await poll;
      expect(answered).toEqual({
        cursor: "e1:2",
        reset: false,
        changes: [{ seq: 2, path: "ipad.md", op: "write", client: "ipad", at: "2026-10-14T08:00:00.000Z" }],
      });
      expect(changes.waiting).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("answers an empty list with the latest cursor when the wait runs out", async () => {
    vi.useFakeTimers();
    try {
      const changes = feed();
      let answered: unknown = null;
      void changes.poll({ since: "e1:0", client: "obsidian", waitMs: 10_000 }).then((r) => (answered = r));
      changes.record([write("own.md", "obsidian")]);
      await vi.advanceTimersByTimeAsync(9_999);
      expect(answered).toBeNull();
      await vi.advanceTimersByTimeAsync(1);
      expect(answered).toEqual({ cursor: "e1:1", reset: false, changes: [] });
      expect(changes.waiting).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("drops a waiter when its signal aborts, and close() answers every waiter", async () => {
    const changes = feed();
    const abort = new AbortController();
    const aborted = changes.poll({ since: "e1:0", client: null, waitMs: 25_000, signal: abort.signal });
    const held = changes.poll({ since: "e1:0", client: null, waitMs: 25_000 });
    expect(changes.waiting).toBe(2);
    abort.abort();
    expect(await aborted).toEqual({ cursor: "e1:0", reset: false, changes: [] });
    expect(changes.waiting).toBe(1);

    changes.close();
    expect(await held).toEqual({ cursor: "e1:0", reset: false, changes: [] });
    expect(changes.waiting).toBe(0);
    // after close nothing waits
    expect(await changes.poll({ since: "e1:0", client: null, waitMs: 25_000 })).toEqual({ cursor: "e1:0", reset: false, changes: [] });
    expect(changes.waiting).toBe(0);
  });

  it("wakes a waiter with reset when its cursor falls out of the log", async () => {
    const changes = feed({ capacity: 2 });
    const poll = changes.poll({ since: "e1:0", client: "me", waitMs: 25_000 });
    changes.record([write("1.md", "me"), write("2.md", "me"), write("3.md", "me")]);
    expect(await poll).toEqual({ cursor: "e1:3", reset: true, changes: [] });
  });
});

describe("/v1/vault/changes", () => {
  async function vaultApp(vaultChanges = new VaultChangeFeed({ epoch: "test" })) {
    const store = new MemoryVaultStore();
    const { app } = await setup({ vault: store, vaultChanges });
    return { app, store, vaultChanges };
  }

  const changes = (app: Express, query: Record<string, string | number> = {}, client?: string) => {
    const req = request(app).get("/v1/vault/changes").query(query).set(AUTH);
    return client === undefined ? req : req.set(CLIENT, client);
  };

  const put = (app: Express, path: string, body: string, client?: string) => {
    const req = request(app).put("/v1/vault/file").query({ path }).set(AUTH).set("Content-Type", "text/markdown");
    return (client === undefined ? req : req.set(CLIENT, client)).send(body);
  };

  it("answers 503 vault_not_configured and requires auth", async () => {
    const { app } = await setup();
    for (const res of [
      await request(app).get("/v1/vault/changes").set(AUTH),
      await request(app).post("/v1/vault/changes").set(AUTH).send({ paths: ["a.md"] }),
    ]) {
      expect(res.status).toBe(503);
      expect(res.body.error.code).toBe("vault_not_configured");
    }
    const { app: configured } = await vaultApp();
    await request(configured).get("/v1/vault/changes").expect(401);
    await request(configured).post("/v1/vault/changes").send({}).expect(401);
  });

  it("returns the current cursor without since", async () => {
    const { app } = await vaultApp();
    const res = await changes(app, { wait: 25 }).expect(200);
    expect(res.headers["cache-control"]).toBe("no-store");
    expect(res.body).toEqual({ cursor: "test:0", reset: false, changes: [] });
  });

  it("records REST writes and deletes with the client header and filters the requester's own", async () => {
    const { app } = await vaultApp();
    await put(app, "Inbox/想法.md", "v1", "ipad-1").expect(201);
    await put(app, "Inbox/想法.md", "v2").expect(200);
    await request(app).delete("/v1/vault/file").query({ path: "Inbox/想法.md" }).set(AUTH).set(CLIENT, "  ipad-1  ").expect(204);
    // failed writes and deletes record nothing
    await put(app, "../x.md", "x", "ipad-1").expect(400);
    await request(app).delete("/v1/vault/file").query({ path: "none.md" }).set(AUTH).expect(404);

    const all = await changes(app, { since: "test:0" }, "obsidian-abc").expect(200);
    expect(all.body).toEqual({
      cursor: "test:3",
      reset: false,
      changes: [
        { seq: 1, path: "Inbox/想法.md", op: "write", client: "ipad-1", at: expect.any(String) },
        { seq: 2, path: "Inbox/想法.md", op: "write", client: null, at: expect.any(String) },
        { seq: 3, path: "Inbox/想法.md", op: "delete", client: "ipad-1", at: expect.any(String) },
      ],
    });
    expect(Number.isNaN(Date.parse(all.body.changes[0].at))).toBe(false);

    const own = await changes(app, { since: "test:0" }, "ipad-1").expect(200);
    expect(own.body).toEqual({
      cursor: "test:3",
      reset: false,
      changes: [{ seq: 2, path: "Inbox/想法.md", op: "write", client: null, at: expect.any(String) }],
    });
    // no header: nothing is filtered
    expect((await changes(app, { since: "test:0" }).expect(200)).body.changes).toHaveLength(3);
  });

  it("holds a long poll until another client writes", async () => {
    const { app, vaultChanges } = await vaultApp();
    const started = Date.now();
    const poll = changes(app, { since: "test:0", wait: 10 }, "obsidian-abc").then((res) => res);
    await vi.waitFor(() => expect(vaultChanges.waiting).toBe(1));

    await put(app, "own.md", "x", "obsidian-abc").expect(201); // its own write does not answer the poll
    expect(vaultChanges.waiting).toBe(1);
    await put(app, "Daily/2026-10-14.md", "# 今天", "ipad-1").expect(201);

    const res = await poll;
    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      cursor: "test:2",
      reset: false,
      changes: [{ seq: 2, path: "Daily/2026-10-14.md", op: "write", client: "ipad-1", at: expect.any(String) }],
    });
    expect(Date.now() - started).toBeLessThan(5000);
    expect(vaultChanges.waiting).toBe(0);
  });

  it("answers an empty list after wait seconds", async () => {
    const { app, vaultChanges } = await vaultApp();
    await put(app, "own.md", "x", "me").expect(201);
    const started = Date.now();
    const res = await changes(app, { since: "test:0", wait: 0.3 }, "me").expect(200);
    expect(Date.now() - started).toBeGreaterThanOrEqual(250);
    expect(res.body).toEqual({ cursor: "test:1", reset: false, changes: [] });
    expect(vaultChanges.waiting).toBe(0);
  });

  it("clamps wait to 0–25 seconds and rejects a non-number", async () => {
    const { app } = await vaultApp();
    // negative = no wait
    expect((await changes(app, { since: "test:0", wait: -5 }).expect(200)).body).toEqual({ cursor: "test:0", reset: false, changes: [] });
    const bad = await changes(app, { since: "test:0", wait: "soon" }).expect(400);
    expect(bad.body.error.code).toBe("invalid_request");
    expect(bad.body.error.message).toContain("wait");
  });

  it("answers reset for a malformed, foreign or future cursor", async () => {
    const { app } = await vaultApp();
    await put(app, "a.md", "x").expect(201);
    for (const since of ["nonsense", "other-epoch:1", "test:2", "test:x"]) {
      const res = await changes(app, { since, wait: 25 }).expect(200);
      expect(res.body, since).toEqual({ cursor: "test:1", reset: true, changes: [] });
    }
  });

  it("answers reset when the cursor is older than the kept changes", async () => {
    const { app } = await vaultApp(new VaultChangeFeed({ epoch: "test", capacity: 2 }));
    for (const path of ["1.md", "2.md", "3.md"]) await put(app, path, "x").expect(201);
    expect((await changes(app, { since: "test:0" }).expect(200)).body).toEqual({ cursor: "test:3", reset: true, changes: [] });
    expect((await changes(app, { since: "test:1" }).expect(200)).body.changes.map((c: { path: string }) => c.path)).toEqual([
      "2.md",
      "3.md",
    ]);
  });

  it("records POSTed external changes per path (or one with path null) under the client header", async () => {
    const { app } = await vaultApp();
    const reported = await request(app)
      .post("/v1/vault/changes")
      .set(AUTH)
      .set(CLIENT, "obsidian-mac")
      .send({ paths: ["Daily/2026-10-14.md", "Café.md", "Daily/2026-10-14.md"] })
      .expect(202);
    expect(reported.body).toEqual({ cursor: "test:2" });

    const empty = await request(app).post("/v1/vault/changes").set(AUTH).set(CLIENT, "obsidian-mac").expect(202);
    expect(empty.body).toEqual({ cursor: "test:3" });
    await request(app).post("/v1/vault/changes").set(AUTH).send({ paths: [] }).expect(202);

    const seen = await changes(app, { since: "test:0" }, "ipad-1").expect(200);
    expect(seen.body.changes).toEqual([
      { seq: 1, path: "Daily/2026-10-14.md", op: "external", client: "obsidian-mac", at: expect.any(String) },
      { seq: 2, path: "Café.md", op: "external", client: "obsidian-mac", at: expect.any(String) },
      { seq: 3, path: null, op: "external", client: "obsidian-mac", at: expect.any(String) },
      { seq: 4, path: null, op: "external", client: null, at: expect.any(String) },
    ]);
    // the reporting device does not hear about its own uploads
    const own = await changes(app, { since: "test:0" }, "obsidian-mac").expect(200);
    expect(own.body.changes.map((c: { seq: number }) => c.seq)).toEqual([4]);
  });

  it("wakes long polls with a POSTed external change", async () => {
    const { app, vaultChanges } = await vaultApp();
    const poll = changes(app, { since: "test:0", wait: 10 }, "ipad-1").then((res) => res);
    await vi.waitFor(() => expect(vaultChanges.waiting).toBe(1));
    await request(app).post("/v1/vault/changes").set(AUTH).set(CLIENT, "obsidian-mac").send({ paths: ["a.md"] }).expect(202);
    const res = await poll;
    expect(res.body.changes).toEqual([{ seq: 1, path: "a.md", op: "external", client: "obsidian-mac", at: expect.any(String) }]);
  });

  it("validates POST bodies and the client header", async () => {
    const { app, vaultChanges } = await vaultApp();
    const post = (body: unknown) => request(app).post("/v1/vault/changes").set(AUTH).send(body as object);

    expect((await post({ paths: ["../x.md"] }).expect(400)).body.error.code).toBe("invalid_path");
    expect((await post({ paths: ["Notes/"] }).expect(400)).body.error.code).toBe("invalid_path");
    expect((await post({ paths: "a.md" }).expect(400)).body.error.code).toBe("invalid_request");
    expect((await post(["a.md"]).expect(400)).body.error.code).toBe("invalid_request");
    const many = Array.from({ length: 101 }, (_, i) => `${i}.md`);
    expect((await post({ paths: many }).expect(400)).body.error.code).toBe("invalid_request");
    await post({ paths: many.slice(0, 100) }).expect(202);
    const badJson = await request(app).post("/v1/vault/changes").set(AUTH).set("Content-Type", "application/json").send("{oops");
    expect(badJson.status).toBe(400);
    expect(badJson.body.error.code).toBe("invalid_json");

    const long = "x".repeat(101);
    const tooLong = await request(app).post("/v1/vault/changes").set(AUTH).set(CLIENT, long).send({}).expect(400);
    expect(tooLong.body.error).toEqual({ code: "invalid_request", message: expect.stringContaining("X-LocalOCR-Client") });
    await put(app, "a.md", "x", long).expect(400);
    await changes(app, { since: "test:0" }, long).expect(400);
    await put(app, "a.md", "x", "y".repeat(100)).expect(201);
    expect(vaultChanges.cursor).toBe("test:101");
  });

  it("describes the change feed in OpenAPI", async () => {
    const { app } = await setup();
    const res = await request(app).get("/v1/openapi.json").set(AUTH).expect(200);
    expect(Object.keys(res.body.paths["/v1/vault/changes"])).toEqual(["get", "post"]);
    const params = res.body.paths["/v1/vault/changes"].get.parameters.map((p: { name: string }) => p.name);
    expect(params).toEqual(["since", "wait", CLIENT]);
    expect(res.body.components.schemas.VaultChanges.required).toEqual(["cursor", "reset", "changes"]);
    expect(res.body.components.schemas.VaultChange.properties.op.enum).toEqual(["write", "delete", "external"]);
  });

  describe("over a real socket", () => {
    const servers: Server[] = [];
    const clients: Client[] = [];

    afterEach(async () => {
      await Promise.all(clients.splice(0).map((client) => client.close()));
      for (const server of servers.splice(0)) {
        server.closeAllConnections();
        await new Promise((resolve) => server.close(resolve));
      }
    });

    async function listen() {
      const vaultChanges = new VaultChangeFeed({ epoch: "test" });
      const { app } = await setup({ vault: new MemoryVaultStore(), vaultChanges });
      const server = app.listen(0, "127.0.0.1");
      servers.push(server);
      await new Promise((resolve) => server.once("listening", resolve));
      const { port } = server.address() as AddressInfo;
      return { app, vaultChanges, base: `http://127.0.0.1:${port}` };
    }

    it("drops the waiter when the client disconnects", async () => {
      const { vaultChanges, base } = await listen();
      const abort = new AbortController();
      const pending = fetch(`${base}/v1/vault/changes?since=test:0&wait=25`, { headers: AUTH, signal: abort.signal }).catch(
        (error: unknown) => error,
      );
      await vi.waitFor(() => expect(vaultChanges.waiting).toBe(1));
      abort.abort();
      expect(await pending).toBeInstanceOf(Error);
      await vi.waitFor(() => expect(vaultChanges.waiting).toBe(0));
    });

    it("records MCP vault_write with client mcp", async () => {
      const { app, base } = await listen();
      const client = new Client({ name: "test-client", version: "1.0.0" });
      await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp`), { requestInit: { headers: AUTH } }));
      clients.push(client);
      const result = await client.callTool({ name: "vault_write", arguments: { path: "Inbox/來自 Claude.md", content: "# 摘要" } });
      expect(result.isError).toBeFalsy();
      const rejected = await client.callTool({ name: "vault_write", arguments: { path: "Inbox/來自 Claude.md", content: "x" } });
      expect(rejected.isError).toBe(true); // nothing recorded for a failed write

      const res = await changes(app, { since: "test:0" }, "ipad-1").expect(200);
      expect(res.body).toEqual({
        cursor: "test:1",
        reset: false,
        changes: [{ seq: 1, path: "Inbox/來自 Claude.md", op: "write", client: "mcp", at: expect.any(String) }],
      });
    });
  });
});
