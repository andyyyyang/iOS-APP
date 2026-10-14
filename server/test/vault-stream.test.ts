import { once } from "node:events";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import request from "supertest";
import { afterEach, describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";
import {
  VAULT_STREAM_CLOSE_NOT_CONFIGURED,
  VAULT_STREAM_CLOSE_UNAUTHORIZED,
  VAULT_STREAM_PATH,
  attachVaultStream,
  type VaultStream,
  type VaultStreamOptions,
} from "../src/http/vault-stream.js";
import { VaultChangeFeed } from "../src/services/vault-changes.js";
import { MemoryVaultStore } from "../src/vault/index.js";
import { API_KEY, AUTH, setup } from "./helpers.js";

const CLIENT = "X-LocalOCR-Client";
const ME = "obsidian-abcdefghijkl";

type Message = Record<string, unknown>;

interface TestSocket {
  ws: WebSocket;
  send(message: unknown): void;
  /** The next message not read yet (waits up to 2 s). */
  next(): Promise<Message>;
  /** Messages received but not read yet. */
  unread(): Message[];
  closed: Promise<{ code: number; reason: string }>;
}

const servers: Server[] = [];
const streams: VaultStream[] = [];
const sockets: WebSocket[] = [];

afterEach(async () => {
  for (const ws of sockets.splice(0)) ws.terminate();
  for (const stream of streams.splice(0)) stream.close();
  for (const server of servers.splice(0)) {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});

async function listen({ vault = true, options = {} }: { vault?: boolean; options?: VaultStreamOptions } = {}) {
  const vaultChanges = new VaultChangeFeed({ epoch: "test" });
  const { app } = await setup({ vault: vault ? new MemoryVaultStore() : null, vaultChanges });
  const server = app.listen(0, "127.0.0.1");
  servers.push(server);
  await once(server, "listening");
  const stream = attachVaultStream(server, app, options);
  streams.push(stream);
  const { port } = server.address() as AddressInfo;
  return { app, stream, vaultChanges, base: `http://127.0.0.1:${port}`, url: `ws://127.0.0.1:${port}${VAULT_STREAM_PATH}` };
}

async function open(url: string, options: { autoPong?: boolean } = {}): Promise<TestSocket> {
  const ws = new WebSocket(url, options);
  sockets.push(ws);
  const inbox: Message[] = [];
  ws.on("message", (data) => inbox.push(JSON.parse(String(data)) as Message));
  const closed = new Promise<{ code: number; reason: string }>((resolve) =>
    ws.on("close", (code, reason) => resolve({ code, reason: String(reason) })),
  );
  await once(ws, "open");
  return {
    ws,
    send: (message) => ws.send(typeof message === "string" ? message : JSON.stringify(message)),
    next: async () => {
      await vi.waitFor(() => expect(inbox.length).toBeGreaterThan(0), { timeout: 2000, interval: 5 });
      return inbox.shift()!;
    },
    unread: () => [...inbox],
    closed,
  };
}

/** Opens a socket and authenticates; resolves with the socket and its ready message. */
async function connect(url: string, auth: Message = {}) {
  const socket = await open(url);
  socket.send({ type: "auth", token: API_KEY, client: ME, ...auth });
  const ready = await socket.next();
  expect(ready.type).toBe("ready");
  return { socket, ready };
}

const put = (base: string, path: string, client?: string) => {
  const req = request(base).put("/v1/vault/file").query({ path }).set(AUTH).set("Content-Type", "text/markdown");
  return (client === undefined ? req : req.set(CLIENT, client)).send("# note");
};

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

describe("GET /v1/vault/stream (WebSocket)", () => {
  it("authenticates with the first message and answers ready with the current cursor", async () => {
    const { url, stream, vaultChanges } = await listen();
    vaultChanges.record([{ path: "old.md", op: "write", client: "ipad-1" }]);
    const { socket, ready } = await connect(url);
    expect(ready).toEqual({ type: "ready", cursor: "test:1", reset: false });
    expect(stream.clients).toBe(1);
    await sleep(50);
    expect(socket.unread()).toEqual([]); // without since: no catch-up

    socket.ws.close();
    await socket.closed;
    await vi.waitFor(() => expect(stream.clients).toBe(0));
  });

  it("rejects a bad or missing key with unauthorized and close 4401", async () => {
    const { url, stream } = await listen();
    for (const auth of [
      { type: "auth", token: "wrong-key", client: ME },
      { type: "auth", client: ME },
      { type: "auth", token: 42 },
      { type: "ping" }, // the first message must be auth
      "not json",
    ]) {
      const socket = await open(url);
      socket.send(auth);
      expect(await socket.next(), JSON.stringify(auth)).toEqual({ type: "error", code: "unauthorized" });
      expect((await socket.closed).code).toBe(VAULT_STREAM_CLOSE_UNAUTHORIZED);
    }
    expect(stream.clients).toBe(0);
  });

  it("closes with 4401 when no auth message arrives in time", async () => {
    const { url } = await listen({ options: { authTimeoutMs: 100 } });
    const socket = await open(url);
    const started = Date.now();
    expect((await socket.closed).code).toBe(VAULT_STREAM_CLOSE_UNAUTHORIZED);
    expect(Date.now() - started).toBeGreaterThanOrEqual(80);
    expect(socket.unread()).toEqual([]);
  });

  it("answers vault_not_configured and close 4503 without a vault (after checking the key)", async () => {
    const { url } = await listen({ vault: false });
    const socket = await open(url);
    socket.send({ type: "auth", token: API_KEY, client: ME });
    expect(await socket.next()).toEqual({ type: "error", code: "vault_not_configured" });
    expect((await socket.closed).code).toBe(VAULT_STREAM_CLOSE_NOT_CONFIGURED);

    const unauthorized = await open(url);
    unauthorized.send({ type: "auth", token: "wrong-key" });
    expect(await unauthorized.next()).toEqual({ type: "error", code: "unauthorized" });
    expect((await unauthorized.closed).code).toBe(VAULT_STREAM_CLOSE_UNAUTHORIZED);
  });

  it("pushes a REST write made by another client", async () => {
    const { url, base } = await listen();
    const { socket } = await connect(url);
    await put(base, "Daily/2026-10-14.md", "ipad-1").expect(201);
    expect(await socket.next()).toEqual({
      type: "changes",
      cursor: "test:1",
      reset: false,
      changes: [{ seq: 1, path: "Daily/2026-10-14.md", op: "write", client: "ipad-1", at: expect.any(String) }],
    });
    await request(base).delete("/v1/vault/file").query({ path: "Daily/2026-10-14.md" }).set(AUTH).expect(204);
    expect(await socket.next()).toMatchObject({
      cursor: "test:2",
      changes: [{ seq: 2, path: "Daily/2026-10-14.md", op: "delete", client: null }],
    });
  });

  it("leaves out the socket's own changes but still advances the cursor", async () => {
    const { url, base } = await listen();
    const { socket } = await connect(url);
    const other = await connect(url, { client: "ipad-1" });
    await put(base, "mine.md", ME).expect(201);
    await sleep(100);
    expect(socket.unread()).toEqual([]); // nothing but its own change: nothing sent
    expect(await other.socket.next()).toMatchObject({ cursor: "test:1", changes: [{ path: "mine.md", client: ME }] });

    await put(base, "ipad.md", "ipad-1").expect(201);
    expect(await socket.next()).toEqual({
      type: "changes",
      cursor: "test:2",
      reset: false,
      changes: [{ seq: 2, path: "ipad.md", op: "write", client: "ipad-1", at: expect.any(String) }],
    });
  });

  it("batches changes recorded within a few milliseconds into one message", async () => {
    const { url, vaultChanges } = await listen();
    const { socket } = await connect(url);
    vaultChanges.record([{ path: "a.md", op: "write", client: "mcp" }]);
    vaultChanges.record([
      { path: "own.md", op: "write", client: ME },
      { path: "b.md", op: "delete", client: null },
    ]);
    const message = await socket.next();
    expect(message).toMatchObject({ type: "changes", cursor: "test:3", reset: false });
    expect((message.changes as { path: string }[]).map((c) => c.path)).toEqual(["a.md", "b.md"]);
    await sleep(100);
    expect(socket.unread()).toEqual([]);
  });

  it("catches up from since: missed changes by others right after ready, reset for an unusable cursor", async () => {
    const { url, vaultChanges } = await listen();
    vaultChanges.record([{ path: "seen.md", op: "write", client: "ipad-1" }]);
    vaultChanges.record([
      { path: "missed.md", op: "write", client: "ipad-1" },
      { path: "own.md", op: "write", client: ME },
      { path: null, op: "external", client: "obsidian-other" },
    ]);

    const { socket, ready } = await connect(url, { since: "test:1" });
    expect(ready).toEqual({ type: "ready", cursor: "test:4", reset: false });
    expect(await socket.next()).toEqual({
      type: "changes",
      cursor: "test:4",
      reset: false,
      changes: [
        { seq: 2, path: "missed.md", op: "write", client: "ipad-1", at: expect.any(String) },
        { seq: 4, path: null, op: "external", client: "obsidian-other", at: expect.any(String) },
      ],
    });
    // the catch-up is not pushed a second time, later changes are
    vaultChanges.record([{ path: "later.md", op: "write", client: "ipad-1" }]);
    expect(await socket.next()).toMatchObject({ cursor: "test:5", changes: [{ seq: 5, path: "later.md" }] });

    const upToDate = await connect(url, { since: "test:5" });
    expect(upToDate.ready).toEqual({ type: "ready", cursor: "test:5", reset: false });
    for (const since of ["other-epoch:3", "test:99", "garbage"]) {
      const stale = await connect(url, { since });
      expect(stale.ready, since).toEqual({ type: "ready", cursor: "test:5", reset: true });
    }
    await sleep(100);
    expect(upToDate.socket.unread()).toEqual([]);
  });

  it("does not push a change again that the catch-up already listed while its batch was pending", async () => {
    const { url, vaultChanges } = await listen({ options: { batchMs: 300 } });
    const { socket: early } = await connect(url);
    const late = await open(url);
    vaultChanges.record([{ path: "a.md", op: "write", client: "ipad-1" }]); // batched for 300 ms
    late.send({ type: "auth", token: API_KEY, client: ME, since: "test:0" });
    expect(await late.next()).toEqual({ type: "ready", cursor: "test:1", reset: false });
    expect(await late.next()).toMatchObject({ type: "changes", cursor: "test:1", changes: [{ seq: 1 }] });
    expect(await early.next()).toMatchObject({ type: "changes", cursor: "test:1", changes: [{ seq: 1 }] });
    await sleep(100);
    expect(late.unread()).toEqual([]);
  });

  it("records a report as external changes, acks it and pushes it to the other sockets", async () => {
    const { url, base } = await listen();
    const { socket: reporter } = await connect(url);
    const { socket: ipad } = await connect(url, { client: "ipad-1" });

    reporter.send({ type: "report", paths: ["Daily/2026-10-14.md", "Café.md", "Daily/2026-10-14.md", "../bad.md", 7] });
    expect(await reporter.next()).toEqual({ type: "ack", cursor: "test:2" });
    expect(await ipad.next()).toEqual({
      type: "changes",
      cursor: "test:2",
      reset: false,
      changes: [
        { seq: 1, path: "Daily/2026-10-14.md", op: "external", client: ME, at: expect.any(String) },
        { seq: 2, path: "Café.md", op: "external", client: ME, at: expect.any(String) },
      ],
    });

    // no paths, or more than 100: one change with path null
    reporter.send({ type: "report" });
    expect(await reporter.next()).toEqual({ type: "ack", cursor: "test:3" });
    reporter.send({ type: "report", paths: Array.from({ length: 101 }, (_, i) => `${i}.md`) });
    expect(await reporter.next()).toEqual({ type: "ack", cursor: "test:4" });
    const nulls = [await ipad.next(), ...ipad.unread()].flatMap((m) => m.changes as { seq: number; path: string | null }[]);
    expect(nulls.map((c) => [c.seq, c.path])).toEqual([
      [3, null],
      [4, null],
    ]);
    await sleep(100);
    expect(reporter.unread()).toEqual([]); // its own reports are not pushed back

    // the long poll sees them too
    const polled = await request(base).get("/v1/vault/changes").query({ since: "test:0" }).set(AUTH).set(CLIENT, "ipad-1");
    expect(polled.body.changes).toHaveLength(4);
  });

  it("answers ping with pong and ignores unknown or malformed messages", async () => {
    const { url } = await listen();
    const { socket } = await connect(url);
    socket.send("{oops");
    socket.send([1, 2]);
    socket.send({ type: "subscribe" });
    socket.send({ type: "auth", token: "wrong-key" }); // already authenticated: ignored
    socket.send({ type: "ping" });
    expect(await socket.next()).toEqual({ type: "pong" });
    expect(socket.ws.readyState).toBe(WebSocket.OPEN);
  });

  it("drops upgrade requests for other paths", async () => {
    const { url } = await listen();
    for (const path of ["/v1/vault/changes", "/v1/vault/stream/x", "/mcp"]) {
      const ws = new WebSocket(url.replace(VAULT_STREAM_PATH, path));
      sockets.push(ws);
      const [error] = (await once(ws, "error")) as [Error];
      expect(error.message, path).toMatch(/socket hang up|ECONNRESET/);
    }
    // the query string is ignored
    const { ready } = await connect(`${url}?v=1`);
    expect(ready.cursor).toBe("test:0");
  });

  it("pings every heartbeat and terminates a socket that does not answer", async () => {
    const { url, stream } = await listen({ options: { heartbeatMs: 50 } });
    const { socket: healthy } = await connect(url);
    const silent = await open(url, { autoPong: false });
    silent.send({ type: "auth", token: API_KEY, client: "silent" });
    expect(await silent.next()).toMatchObject({ type: "ready" });
    let pings = 0;
    healthy.ws.on("ping", () => (pings += 1));

    expect((await silent.closed).code).toBe(1006); // terminated, no close frame
    await sleep(200);
    expect(pings).toBeGreaterThanOrEqual(2);
    expect(healthy.ws.readyState).toBe(WebSocket.OPEN);
    expect(stream.clients).toBe(1);
  });

  it("is described in OpenAPI", async () => {
    const { app } = await setup();
    const res = await request(app).get("/v1/openapi.json").set(AUTH).expect(200);
    const stream = res.body.paths[VAULT_STREAM_PATH];
    expect(Object.keys(stream)).toEqual(["get"]);
    expect(stream.get.security).toEqual([]);
    expect(Object.keys(stream.get.responses)).toContain("101");
    expect(stream.get.description).toContain('{"type":"auth"');
  });

  it("closes every socket with 1001 on shutdown and refuses new ones", async () => {
    const { url, stream, vaultChanges } = await listen();
    const { socket } = await connect(url);
    vaultChanges.record([{ path: "last.md", op: "write", client: "ipad-1" }]);
    stream.close();
    expect(await socket.next()).toMatchObject({ type: "changes", changes: [{ path: "last.md" }] }); // pending push sent first
    expect((await socket.closed).code).toBe(1001);
    expect(vaultChanges.subscribers).toBe(0);

    const late = new WebSocket(url);
    sockets.push(late);
    await once(late, "error");
  });
});
