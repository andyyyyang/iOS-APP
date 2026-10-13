import { createHash } from "node:crypto";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import {
  GetObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
  PutObjectCommand,
  type S3Client,
} from "@aws-sdk/client-s3";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { Express } from "express";
import request from "supertest";
import { afterEach, describe, expect, it, vi } from "vitest";
import { loadConfig, parseVaultConfig } from "../src/config.js";
import { createVaultStore, MemoryVaultStore, S3VaultStore, VaultStorageError } from "../src/vault/index.js";
import { metadataMtime } from "../src/vault/s3.js";
import { AUTH, setup } from "./helpers.js";

const md5 = (body: string | Buffer) => createHash("md5").update(body).digest("hex");

async function vaultApp(store: MemoryVaultStore | S3VaultStore = new MemoryVaultStore()) {
  const { app } = await setup({ vault: store });
  return { app, store };
}

function put(app: Express, path: string, body: string | Buffer, headers: Record<string, string> = {}) {
  return request(app)
    .put("/v1/vault/file")
    .query({ path })
    .set(AUTH)
    .set({ "Content-Type": "application/octet-stream", ...headers })
    .send(body); // strings as-is: superagent would JSON-serialize a Buffer sent as application/json
}

/** GET a vault file as raw bytes whatever its Content-Type. */
function getRaw(app: Express, path: string) {
  return request(app)
    .get("/v1/vault/file")
    .query({ path })
    .set(AUTH)
    .buffer(true)
    .parse((res, done) => {
      const chunks: Buffer[] = [];
      res.on("data", (chunk: Buffer) => chunks.push(chunk));
      res.on("end", () => done(null, Buffer.concat(chunks)));
    });
}

describe("vault REST", () => {
  it("answers 503 vault_not_configured when VAULT_S3_* is missing", async () => {
    const { app } = await setup();
    const status = await request(app).get("/v1/vault/status").set(AUTH).expect(200);
    expect(status.body).toEqual({ configured: false, prefix: "" });

    const responses = [
      await request(app).get("/v1/vault/files").set(AUTH),
      await request(app).get("/v1/vault/file").query({ path: "a.md" }).set(AUTH),
      await put(app, "a.md", "x"),
      await request(app).delete("/v1/vault/file").query({ path: "a.md" }).set(AUTH),
      await request(app).get("/v1/vault/search").query({ q: "x" }).set(AUTH),
    ];
    for (const res of responses) {
      expect(res.status).toBe(503);
      expect(res.body).toEqual({
        error: { code: "vault_not_configured", message: "Vault storage is not configured (set VAULT_S3_* variables)" },
      });
    }
  });

  it("requires auth", async () => {
    const { app } = await vaultApp();
    await request(app).get("/v1/vault/status").expect(401);
    await request(app).put("/v1/vault/file").query({ path: "a.md" }).send(Buffer.from("x")).expect(401);
  });

  it("reports status with the key prefix", async () => {
    const { app } = await vaultApp(new MemoryVaultStore("vault/"));
    const res = await request(app).get("/v1/vault/status").set(AUTH).expect(200);
    expect(res.body).toEqual({ configured: true, prefix: "vault/" });
  });

  it("rejects invalid paths with 400 invalid_path", async () => {
    const { app } = await vaultApp();
    const bad = [
      "",
      "/a.md",
      "Notes/",
      "a/../b.md",
      "./a.md",
      "a/./b.md",
      "..",
      "a//b.md",
      "a\\b.md",
      "a\u0000b.md",
      "a\nb.md",
      "\u007f.md",
      `${"長".repeat(342)}.md`, // 1029 UTF-8 bytes
    ];
    for (const path of bad) {
      const res = await put(app, path, "x");
      expect(res.status, JSON.stringify(path)).toBe(400);
      expect(res.body.error.code).toBe("invalid_path");
      await request(app).get("/v1/vault/file").query({ path }).set(AUTH).expect(400);
    }
    const missing = await request(app).get("/v1/vault/file").set(AUTH).expect(400);
    expect(missing.body.error).toEqual({ code: "invalid_path", message: "Invalid path: path is required" });
    await request(app).get("/v1/vault/files").query({ prefix: "../x" }).set(AUTH).expect(400);
    await request(app).get("/v1/vault/files").query({ prefix: "/" }).set(AUTH).expect(400);

    // 1024 bytes exactly is fine
    await put(app, `${"a".repeat(1021)}.md`, "x").expect(201);
  });

  it("NFC-normalizes paths and finds files stored with NFD names", async () => {
    const { app, store } = await vaultApp();
    const created = await put(app, "Café.md", "x").expect(201);
    expect(created.body.path).toBe("Café.md");
    await getRaw(app, "Café.md").expect(200);

    // e.g. uploaded by Remotely Save from macOS with a decomposed name
    await store.write("Notes/ポ゙.md".normalize("NFD"), Buffer.from("nfd"), { mtime: 1, contentType: "text/markdown" });
    const res = await getRaw(app, "Notes/ポ゙.md".normalize("NFC")).expect(200);
    expect(res.body.toString()).toBe("nfd");
    const overwritten = await put(app, "Notes/ポ゙.md".normalize("NFC"), "updated").expect(200);
    expect(overwritten.body.path).toBe("Notes/ポ゙.md".normalize("NFD"));
  });

  it("creates with PUT (201) and serves the raw content with ETag and mtime headers", async () => {
    const { app } = await vaultApp();
    const content = "---\ntags: [idea]\n---\n# 想法\n內容";
    const created = await put(app, "Notes/想法.md", content, {
      "Content-Type": "text/markdown",
      "X-Vault-Mtime": "1760000000123",
    }).expect(201);
    const etag = md5(content);
    expect(created.body).toEqual({ path: "Notes/想法.md", size: Buffer.byteLength(content), mtime: 1760000000123, etag });
    expect(created.headers.etag).toBe(`"${etag}"`);

    const res = await request(app).get("/v1/vault/file").query({ path: "Notes/想法.md" }).set(AUTH).expect(200);
    expect(res.text).toBe(content);
    expect(res.headers["content-type"]).toBe("text/markdown; charset=utf-8");
    expect(res.headers.etag).toBe(`"${etag}"`);
    expect(res.headers["x-vault-mtime"]).toBe("1760000000123");
    expect(res.headers["last-modified"]).toBe(new Date(1760000000123).toUTCString());

    const missing = await request(app).get("/v1/vault/file").query({ path: "Notes/none.md" }).set(AUTH).expect(404);
    expect(missing.body.error.code).toBe("not_found");
  });

  it("exposes the vault headers to CORS clients", async () => {
    const { app } = await vaultApp();
    await put(app, "a.md", "x").expect(201);
    const res = await getRaw(app, "a.md").set("Origin", "https://example.com").expect(200);
    const exposed = String(res.headers["access-control-expose-headers"]);
    for (const name of ["ETag", "Last-Modified", "X-Vault-Mtime"]) expect(exposed).toContain(name);
  });

  it("overwrites with a matching If-Match (200) and rejects a stale one (412 + currentEtag)", async () => {
    const { app } = await vaultApp();
    const first = await put(app, "note.md", "v1").expect(201);
    const second = await put(app, "note.md", "v2", { "If-Match": `"${first.body.etag}"` }).expect(200);
    expect(second.body.etag).toBe(md5("v2"));

    const stale = await put(app, "note.md", "v3", { "If-Match": `"${first.body.etag}"` }).expect(412);
    expect(stale.body).toEqual({
      error: { code: "precondition_failed", message: expect.any(String), currentEtag: second.body.etag },
    });
    // unquoted and weak forms are accepted too
    await put(app, "note.md", "v3", { "If-Match": second.body.etag }).expect(200);
    await put(app, "note.md", "v4", { "If-Match": `W/"${md5("v3")}"` }).expect(200);
    expect((await getRaw(app, "note.md")).body.toString()).toBe("v4");

    const missing = await put(app, "other.md", "x", { "If-Match": `"${first.body.etag}"` }).expect(412);
    expect(missing.body.error.currentEtag).toBeNull();
    await getRaw(app, "other.md").expect(404);
  });

  it("only creates with If-None-Match: *", async () => {
    const { app } = await vaultApp();
    const created = await put(app, "new.md", "a", { "If-None-Match": "*" }).expect(201);
    const conflict = await put(app, "new.md", "b", { "If-None-Match": "*" }).expect(412);
    expect(conflict.body.error).toMatchObject({ code: "precondition_failed", currentEtag: created.body.etag });
    expect((await getRaw(app, "new.md")).body.toString()).toBe("a");
  });

  it("round-trips X-Vault-Mtime, defaults it to now and validates it", async () => {
    const { app } = await vaultApp();
    await put(app, "a.md", "x", { "X-Vault-Mtime": "1700000000000" }).expect(201);
    expect((await getRaw(app, "a.md")).headers["x-vault-mtime"]).toBe("1700000000000");

    const before = Date.now();
    const res = await put(app, "b.md", "x").expect(201);
    expect(res.body.mtime).toBeGreaterThanOrEqual(before);
    expect(res.body.mtime).toBeLessThanOrEqual(Date.now());

    for (const value of ["abc", "1.5", "-1"]) {
      const bad = await put(app, "c.md", "x", { "X-Vault-Mtime": value }).expect(400);
      expect(bad.body.error).toMatchObject({ code: "invalid_request", message: expect.stringContaining("X-Vault-Mtime") });
    }
  });

  it("lists files by folder (with child folders) and recursively", async () => {
    const { app } = await vaultApp();
    for (const path of ["b.md", "a.md", "Daily/2026-10-13.md", "Daily/2026-10-12.md", "Daily/Archive/old.md", "Projects/plan.canvas"]) {
      await put(app, path, path).expect(201);
    }

    const root = await request(app).get("/v1/vault/files").set(AUTH).expect(200);
    expect(root.body).toEqual({
      items: [
        { path: "a.md", size: 4, mtime: expect.any(Number), etag: md5("a.md") },
        { path: "b.md", size: 4, mtime: expect.any(Number), etag: md5("b.md") },
      ],
      folders: ["Daily/", "Projects/"],
    });

    const daily = await request(app).get("/v1/vault/files").query({ prefix: "Daily", recursive: "false" }).set(AUTH).expect(200);
    expect(daily.body.items.map((item: { path: string }) => item.path)).toEqual(["Daily/2026-10-12.md", "Daily/2026-10-13.md"]);
    expect(daily.body.folders).toEqual(["Daily/Archive/"]);

    const all = await request(app).get("/v1/vault/files").query({ recursive: "true" }).set(AUTH).expect(200);
    expect(all.body.folders).toBeUndefined();
    expect(all.body.items.map((item: { path: string }) => item.path)).toEqual([
      "Daily/2026-10-12.md",
      "Daily/2026-10-13.md",
      "Daily/Archive/old.md",
      "Projects/plan.canvas",
      "a.md",
      "b.md",
    ]);

    const under = await request(app).get("/v1/vault/files").query({ prefix: "Daily/", recursive: "1" }).set(AUTH).expect(200);
    expect(under.body.items).toHaveLength(3);

    const bad = await request(app).get("/v1/vault/files").query({ recursive: "maybe" }).set(AUTH).expect(400);
    expect(bad.body.error.code).toBe("invalid_request");
  });

  it("deletes with or without If-Match and 404s when missing", async () => {
    const { app } = await vaultApp();
    const del = (path: string, headers: Record<string, string> = {}) =>
      request(app).delete("/v1/vault/file").query({ path }).set(AUTH).set(headers);

    const missing = await del("none.md").expect(404);
    expect(missing.body.error.code).toBe("not_found");

    const created = await put(app, "a.md", "v1").expect(201);
    await put(app, "a.md", "v2").expect(200);
    const stale = await del("a.md", { "If-Match": `"${created.body.etag}"` }).expect(412);
    expect(stale.body.error.currentEtag).toBe(md5("v2"));
    await del("a.md", { "If-Match": `"${md5("v2")}"` }).expect(204);
    await getRaw(app, "a.md").expect(404);

    await put(app, "b.md", "x").expect(201);
    await del("b.md").expect(204);
    await del("b.md").expect(404);
  });

  it("stores bodies byte-for-byte: binary files, JSON files and uploads over 5mb", async () => {
    const { app } = await vaultApp();
    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0xff]), Buffer.alloc(64, 7)]);
    await put(app, "Attachments/photo.png", png, { "Content-Type": "image/png" }).expect(201);
    const image = await getRaw(app, "Attachments/photo.png").expect(200);
    expect(image.headers["content-type"]).toBe("image/png");
    expect(Buffer.compare(image.body, png)).toBe(0);

    // the global JSON parser must not touch vault uploads
    const canvas = '{\n  "nodes": [],\n  "edges": []\n}\n';
    await put(app, "Board.canvas", canvas, { "Content-Type": "application/json" }).expect(201);
    const board = await getRaw(app, "Board.canvas").expect(200);
    expect(board.headers["content-type"]).toBe("application/json");
    expect(board.body.toString()).toBe(canvas);
    await put(app, "broken.json", "{not json", { "Content-Type": "application/json" }).expect(201);

    const big = Buffer.alloc(6 * 1024 * 1024, "a");
    const res = await put(app, "big.txt", big, { "Content-Type": "text/plain" }).expect(201);
    expect(res.body.size).toBe(big.length);
    const tooBig = await put(app, "huge.bin", Buffer.alloc(25 * 1024 * 1024 + 1)).expect(413);
    expect(tooBig.body.error).toEqual({ code: "payload_too_large", message: "Request body exceeds 25mb" });

    const empty = await put(app, "empty.md", Buffer.alloc(0)).expect(201);
    expect(empty.body.size).toBe(0);
    const unknown = await getRaw(app, "Attachments/photo.png").expect(200);
    expect(unknown.headers["x-content-type-options"]).toBe("nosniff");
  });

  it("searches names and contents of text notes, newest first, with snippets", async () => {
    const { app } = await vaultApp();
    const files: [string, string, number][] = [
      ["Inbox/購物清單.md", "牛奶\n雞蛋", 1000],
      ["Notes/budget-2026.md", "# Plan\nnothing here", 2000],
      ["Notes/meeting.md", `${"Lorem ipsum dolor sit amet. ".repeat(10)}Budget review\nwith the team. ${"More words. ".repeat(20)}`, 3000],
      ["Notes/other.txt", "BUDGET in caps", 4000],
      ["Attachments/budget.png", "budget", 5000],
      [".obsidian/budget.json", '{"budget":1}', 6000],
    ];
    for (const [path, body, mtime] of files) await put(app, path, body, { "X-Vault-Mtime": String(mtime) }).expect(201);

    const res = await request(app).get("/v1/vault/search").query({ q: "budget" }).set(AUTH).expect(200);
    expect(res.body.items.map((item: { path: string }) => item.path)).toEqual([
      "Notes/other.txt",
      "Notes/meeting.md",
      "Notes/budget-2026.md",
    ]);
    const [other, meeting, byName] = res.body.items;
    expect(other).toEqual({ path: "Notes/other.txt", mtime: 4000, snippet: "BUDGET in caps" });
    expect(meeting.snippet).toMatch(/^…/);
    expect(meeting.snippet).toContain("Budget review with the team.");
    expect(meeting.snippet.length).toBeLessThanOrEqual(124);
    expect(byName.snippet).toBe("# Plan nothing here");

    const limited = await request(app).get("/v1/vault/search").query({ q: "budget", limit: 1 }).set(AUTH).expect(200);
    expect(limited.body.items.map((item: { path: string }) => item.path)).toEqual(["Notes/other.txt"]);

    const inbox = await request(app).get("/v1/vault/search").query({ q: "牛奶", prefix: "Inbox/" }).set(AUTH).expect(200);
    expect(inbox.body.items).toEqual([{ path: "Inbox/購物清單.md", mtime: 1000, snippet: "牛奶 雞蛋" }]);
    const elsewhere = await request(app).get("/v1/vault/search").query({ q: "牛奶", prefix: "Notes" }).set(AUTH).expect(200);
    expect(elsewhere.body.items).toEqual([]);

    // regex metacharacters are matched literally
    const literal = await request(app).get("/v1/vault/search").query({ q: "(caps" }).set(AUTH).expect(200);
    expect(literal.body.items).toEqual([]);

    const empty = await request(app).get("/v1/vault/search").query({ q: "  " }).set(AUTH).expect(400);
    expect(empty.body.error.code).toBe("invalid_request");
  });

  it("returns 502 vault_storage_error when the bucket fails", async () => {
    const send = vi.fn(async () => {
      throw Object.assign(new Error("Access Denied"), { name: "AccessDenied", $metadata: { httpStatusCode: 403 } });
    });
    const store = new S3VaultStore({ bucket: "b", prefix: "", client: { send } as unknown as S3Client });
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    const { app } = await vaultApp(store);
    const res = await request(app).get("/v1/vault/files").set(AUTH).expect(502);
    expect(res.body.error).toEqual({
      code: "vault_storage_error",
      message: "Vault storage request failed: AccessDenied (HTTP 403): Access Denied",
    });
    expect(errors).toHaveBeenCalled();
    errors.mockRestore();
  });

  it("describes the vault endpoints in OpenAPI", async () => {
    const { app } = await setup();
    const res = await request(app).get("/v1/openapi.json").set(AUTH).expect(200);
    for (const path of ["/v1/vault/status", "/v1/vault/files", "/v1/vault/file", "/v1/vault/search", "/v1/vault/remotely-save"]) {
      expect(res.body.paths[path], path).toBeDefined();
    }
    expect(Object.keys(res.body.paths["/v1/vault/file"])).toEqual(expect.arrayContaining(["get", "put", "delete"]));
    expect(res.body.components.schemas.PreconditionFailed).toBeDefined();
  });
});

describe("GET /v1/vault/remotely-save", () => {
  const vaultConfig = {
    endpoint: "https://t3.storageapi.dev",
    bucket: "obsidian-vault-abc",
    region: "auto",
    accessKeyId: "tid_key",
    secretAccessKey: "tsec_secret",
    forcePathStyle: false,
    prefix: "",
  };

  const get = (app: Express, query: Record<string, string> = {}) =>
    request(app).get("/v1/vault/remotely-save").query(query).set(AUTH);

  it("answers 503 vault_not_configured without bucket credentials", async () => {
    const notConfigured = {
      error: { code: "vault_not_configured", message: "Vault storage is not configured (set VAULT_S3_* variables)" },
    };
    const { app } = await setup();
    expect((await get(app, { vault: "V" }).expect(503)).body).toEqual(notConfigured);
    // a store alone (memory, no S3 keys) has nothing to hand to Remotely Save
    const { app: memory } = await setup({ vault: new MemoryVaultStore() });
    expect((await get(memory).expect(503)).body).toEqual(notConfigured);
  });

  it("requires auth", async () => {
    const { app } = await setup({ vault: new MemoryVaultStore(), vaultConfig });
    await request(app).get("/v1/vault/remotely-save").expect(401);
  });

  it("returns complete S3 settings and Remotely Save's import URI for the vault", async () => {
    const { app } = await setup({ vault: new MemoryVaultStore(), vaultConfig });
    const vault = "My Vault 筆記 & 100%+";
    const res = await get(app, { vault }).expect(200);
    expect(res.headers["cache-control"]).toBe("no-store");
    expect(res.body.settings).toEqual({
      serviceType: "s3",
      s3: {
        s3Endpoint: "https://t3.storageapi.dev",
        s3Region: "auto",
        s3AccessKeyID: "tid_key",
        s3SecretAccessKey: "tsec_secret",
        s3BucketName: "obsidian-vault-abc",
        partsConcurrency: 20,
        forcePathStyle: false,
        remotePrefix: "",
        useAccurateMTime: true,
        reverseProxyNoSignUrl: "",
        generateFolderObject: false,
        bypassCorsLocally: true,
      },
      autoRunEveryMilliseconds: 300_000,
      initRunAfterMilliseconds: 10_000,
      syncOnSaveAfterMilliseconds: 1000,
      agreeToUseSyncV3: true,
      syncUnderscoreItems: true,
    });

    // exactly how Remotely Save's exportQrCodeUri builds it
    const data = encodeURIComponent(JSON.stringify(res.body.settings));
    expect(res.body.uri).toBe(
      `obsidian://remotely-save?func=settings&version=localocr&vault=${encodeURIComponent(vault)}&data=${data}`,
    );
    // and how its parseUriByHand / importQrCodeUri read it back
    const params = Object.fromEntries(new URL(res.body.uri).searchParams);
    expect(params).toEqual({ func: "settings", version: "localocr", vault, data: expect.any(String) });
    expect(JSON.parse(params.data!)).toEqual(res.body.settings);
  });

  it("passes region, URL style and prefix through and omits the URI without a vault name", async () => {
    const { app } = await setup({
      vault: new MemoryVaultStore("vault/"),
      vaultConfig: { ...vaultConfig, region: "us-east-1", forcePathStyle: true, prefix: "vault/" },
    });
    const res = await get(app).expect(200);
    expect(res.body.uri).toBeNull();
    expect(res.body.settings.s3).toMatchObject({ s3Region: "us-east-1", forcePathStyle: true, remotePrefix: "vault/" });
    expect((await get(app, { vault: "" }).expect(200)).body.uri).toBeNull();

    const tooLong = await get(app, { vault: "x".repeat(201) }).expect(400);
    expect(tooLong.body.error.code).toBe("invalid_request");
  });
});

describe("vault MCP tools", () => {
  const servers: Server[] = [];
  const clients: Client[] = [];

  afterEach(async () => {
    await Promise.all(clients.splice(0).map((client) => client.close()));
    await Promise.all(servers.splice(0).map((server) => new Promise((resolve) => server.close(resolve))));
  });

  async function connect(vault: MemoryVaultStore | null) {
    const { app } = await setup({ vault });
    const server = app.listen(0, "127.0.0.1");
    servers.push(server);
    await new Promise((resolve) => server.once("listening", resolve));
    const { port } = server.address() as AddressInfo;
    const client = new Client({ name: "test-client", version: "1.0.0" });
    await client.connect(new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`), { requestInit: { headers: AUTH } }));
    clients.push(client);
    return { app, client };
  }

  type ToolResult = Awaited<ReturnType<Client["callTool"]>>;
  const texts = (result: ToolResult) => (result.content as { type: string; text: string }[]).map((block) => block.text);
  const parse = (result: ToolResult) => JSON.parse(texts(result)[0]!);

  it("writes, reads, lists and searches notes with etag preconditions", async () => {
    const store = new MemoryVaultStore();
    const { app, client } = await connect(store);
    const note = "---\ntags: [inbox]\n---\n# 想法\n第一版";

    const created = await client.callTool({ name: "vault_write", arguments: { path: "Inbox/想法.md", content: note, createOnly: true } });
    expect(created.isError).toBeFalsy();
    expect(parse(created)).toMatchObject({ path: "Inbox/想法.md", etag: md5(note), created: true });

    const again = await client.callTool({ name: "vault_write", arguments: { path: "Inbox/想法.md", content: "x", createOnly: true } });
    expect(again.isError).toBe(true);
    expect(parse(again).error).toMatchObject({ code: "precondition_failed", currentEtag: md5(note) });

    // Without ifMatch an existing note is never overwritten, even without createOnly
    const blind = await client.callTool({ name: "vault_write", arguments: { path: "Inbox/想法.md", content: "x" } });
    expect(blind.isError).toBe(true);
    expect(parse(blind).error).toMatchObject({ code: "precondition_failed", currentEtag: md5(note) });
    const fresh = await client.callTool({ name: "vault_write", arguments: { path: "Inbox/新的.md", content: "新筆記" } });
    expect(parse(fresh)).toMatchObject({ path: "Inbox/新的.md", created: true });

    const read = await client.callTool({ name: "vault_read", arguments: { path: "Inbox/想法.md" } });
    expect(read.isError).toBeFalsy();
    const [meta, text] = texts(read);
    expect(JSON.parse(meta!)).toMatchObject({ path: "Inbox/想法.md", size: Buffer.byteLength(note), etag: md5(note) });
    expect(text).toBe(note);

    const edited = `${note}\n第二版`;
    const updated = await client.callTool({
      name: "vault_write",
      arguments: { path: "Inbox/想法.md", content: edited, ifMatch: JSON.parse(meta!).etag },
    });
    expect(parse(updated)).toMatchObject({ etag: md5(edited), created: false });

    const stale = await client.callTool({
      name: "vault_write",
      arguments: { path: "Inbox/想法.md", content: "lost update", ifMatch: md5(note) },
    });
    expect(stale.isError).toBe(true);
    expect(parse(stale).error).toMatchObject({ code: "precondition_failed", currentEtag: md5(edited) });
    expect((await getRaw(app, "Inbox/想法.md")).body.toString()).toBe(edited);

    const list = parse(await client.callTool({ name: "vault_list", arguments: {} }));
    expect(list).toEqual({ items: [], folders: ["Inbox/"] });
    const all = parse(await client.callTool({ name: "vault_list", arguments: { recursive: true } }));
    expect(all.items.map((item: { path: string }) => item.path)).toEqual(["Inbox/想法.md", "Inbox/新的.md"]);

    const search = parse(await client.callTool({ name: "vault_search", arguments: { query: "第二版" } }));
    expect(search.items).toHaveLength(1);
    expect(search.items[0]).toMatchObject({ path: "Inbox/想法.md", snippet: expect.stringContaining("第二版") });

    await store.write("photo.png", Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x00]), { mtime: 5, contentType: "image/png" });
    const binary = await client.callTool({ name: "vault_read", arguments: { path: "photo.png" } });
    expect(texts(binary)).toHaveLength(1);
    expect(parse(binary)).toMatchObject({ path: "photo.png", size: 5, mtime: 5, binary: true });

    const missing = await client.callTool({ name: "vault_read", arguments: { path: "none.md" } });
    expect(missing.isError).toBe(true);
    expect(parse(missing).error.code).toBe("not_found");

    const invalid = await client.callTool({ name: "vault_write", arguments: { path: "../x.md", content: "x" } });
    expect(parse(invalid).error.code).toBe("invalid_path");
  });

  it("describes the vault tools and reports vault_not_configured", async () => {
    const { client } = await connect(null);
    const { tools } = await client.listTools();
    const write = tools.find((tool) => tool.name === "vault_write")!;
    expect(write.description).toContain("Remotely Save");
    expect(write.description).toContain("ifMatch");
    expect(write.inputSchema.required).toEqual(expect.arrayContaining(["path", "content"]));
    expect(tools.some((tool) => tool.name.includes("delete") && tool.name.startsWith("vault"))).toBe(false);

    const result = await client.callTool({ name: "vault_list", arguments: {} });
    expect(result.isError).toBe(true);
    expect(parse(result).error.code).toBe("vault_not_configured");
  });
});

describe("S3VaultStore", () => {
  type Command = { input: Record<string, unknown> };

  function fakeS3(respond: (command: Command) => unknown) {
    const send = vi.fn(async (command: Command) => respond(command));
    const store = new S3VaultStore({ bucket: "obsidian-vault-abc", prefix: "vault/", client: { send } as unknown as S3Client });
    return { send, store };
  }

  it("writes Remotely Save style MTime/CTime metadata (seconds) under the prefixed key", async () => {
    const { send, store } = fakeS3(() => ({ ETag: '"abc123"' }));
    const entry = await store.write("Notes/想法.md", Buffer.from("hi"), {
      mtime: 1760000000123,
      contentType: "text/markdown; charset=utf-8",
    });
    expect(entry).toEqual({ path: "Notes/想法.md", size: 2, mtime: 1760000000123, etag: "abc123" });

    const command = send.mock.calls[0]![0];
    expect(command).toBeInstanceOf(PutObjectCommand);
    expect(command.input).toMatchObject({
      Bucket: "obsidian-vault-abc",
      Key: "vault/Notes/想法.md",
      ContentType: "text/markdown; charset=utf-8",
      Metadata: { MTime: "1760000000.123", CTime: "1760000000.123" },
    });
  });

  it("lists with Delimiter and pagination, skipping folder markers and stripping the prefix", async () => {
    const modified = new Date("2026-10-13T00:00:00Z");
    const { send, store } = fakeS3((command) =>
      command.input.ContinuationToken
        ? {
            IsTruncated: false,
            Contents: [{ Key: "vault/Notes/b.md", Size: 2, LastModified: modified, ETag: '"b"' }],
            CommonPrefixes: [{ Prefix: "vault/Notes/Sub/" }],
          }
        : {
            IsTruncated: true,
            NextContinuationToken: "page-2",
            Contents: [
              { Key: "vault/Notes/", Size: 0, LastModified: modified, ETag: '"d41d8cd98f00b204e9800998ecf8427e"' },
              { Key: "vault/Notes/a.md", Size: 1, LastModified: modified, ETag: '"a"' },
            ],
          },
    );
    const listing = await store.list("Notes/", { recursive: false });
    expect(listing).toEqual({
      items: [
        { path: "Notes/a.md", size: 1, mtime: modified.getTime(), etag: "a" },
        { path: "Notes/b.md", size: 2, mtime: modified.getTime(), etag: "b" },
      ],
      folders: ["Notes/Sub/"],
    });
    expect(send).toHaveBeenCalledTimes(2);
    const [first, second] = send.mock.calls.map(([command]) => command);
    expect(first).toBeInstanceOf(ListObjectsV2Command);
    expect(first!.input).toEqual({ Bucket: "obsidian-vault-abc", Prefix: "vault/Notes/", Delimiter: "/" });
    expect(second!.input).toEqual({ Bucket: "obsidian-vault-abc", Prefix: "vault/Notes/", Delimiter: "/", ContinuationToken: "page-2" });

    send.mockClear();
    await store.list("", { recursive: true });
    expect(send.mock.calls[0]![0].input).toEqual({ Bucket: "obsidian-vault-abc", Prefix: "vault/" });
  });

  it("reads mtime from MTime metadata (seconds or legacy milliseconds), else LastModified", async () => {
    const modified = new Date("2026-10-13T00:00:00Z");
    let metadata: Record<string, string> | undefined = { mtime: "1760000000.5" };
    const { send, store } = fakeS3((command) => {
      if (command instanceof HeadObjectCommand) {
        if (command.input.Key === "vault/missing.md") {
          throw Object.assign(new Error("NotFound"), { name: "NotFound", $metadata: { httpStatusCode: 404 } });
        }
        return { ContentLength: 3, LastModified: modified, ETag: '"e"', Metadata: metadata };
      }
      if (command instanceof GetObjectCommand) {
        return {
          LastModified: modified,
          ETag: '"e"',
          Metadata: metadata,
          Body: { transformToByteArray: async () => new TextEncoder().encode("abc") },
        };
      }
      throw new Error("unexpected command");
    });

    expect(await store.stat("a.md")).toEqual({ path: "a.md", size: 3, mtime: 1760000000500, etag: "e" });
    expect(send.mock.calls[0]![0].input).toEqual({ Bucket: "obsidian-vault-abc", Key: "vault/a.md" });
    metadata = undefined;
    expect((await store.stat("a.md"))!.mtime).toBe(modified.getTime());
    expect(await store.stat("missing.md")).toBeNull();

    metadata = { MTime: "1760000000123" }; // milliseconds, written by old Remotely Save versions
    const file = await store.read("a.md");
    expect(file).toMatchObject({ path: "a.md", size: 3, mtime: 1760000000123, etag: "e" });
    expect(file!.body.toString()).toBe("abc");

    expect(metadataMtime({ "x-other": "1" })).toBeNull();
    expect(metadataMtime({ mtime: "not a number" })).toBeNull();
  });

  it("wraps SDK failures in VaultStorageError (404 on a missing bucket is not 'file missing')", async () => {
    const { store } = fakeS3(() => {
      throw Object.assign(new Error("The specified bucket does not exist"), {
        name: "NoSuchBucket",
        $metadata: { httpStatusCode: 404 },
      });
    });
    await expect(store.read("a.md")).rejects.toBeInstanceOf(VaultStorageError);
    await expect(store.list("", { recursive: true })).rejects.toThrow(/NoSuchBucket \(HTTP 404\)/);
  });
});

describe("vault config", () => {
  const full = {
    VAULT_S3_ENDPOINT: "https://t3.storageapi.dev",
    VAULT_S3_BUCKET: "obsidian-vault-abc",
    VAULT_S3_ACCESS_KEY_ID: "tid_key",
    VAULT_S3_SECRET_ACCESS_KEY: "tsec_secret",
  };

  it("is configured only when endpoint, bucket and both keys are set", () => {
    const warnings: string[] = [];
    const logger = { warn: (message: string) => warnings.push(message) };
    expect(parseVaultConfig({}, logger)).toBeNull();
    expect(warnings).toEqual([]);

    expect(parseVaultConfig({ ...full, VAULT_S3_SECRET_ACCESS_KEY: " " }, logger)).toBeNull();
    expect(warnings).toEqual(["[config] WARNING: vault storage disabled; missing VAULT_S3_SECRET_ACCESS_KEY"]);
    expect(warnings.join()).not.toContain("tid_key");

    expect(parseVaultConfig(full, logger)).toEqual({
      endpoint: "https://t3.storageapi.dev",
      bucket: "obsidian-vault-abc",
      region: "auto",
      accessKeyId: "tid_key",
      secretAccessKey: "tsec_secret",
      forcePathStyle: false,
      prefix: "",
    });
    expect(
      parseVaultConfig({ ...full, VAULT_S3_REGION: "us-east-1", VAULT_S3_FORCE_PATH_STYLE: "true", VAULT_PREFIX: "vault/" }, logger),
    ).toMatchObject({ region: "us-east-1", forcePathStyle: true, prefix: "vault/" });
  });

  it("requires VAULT_PREFIX to end with a slash", () => {
    expect(() => parseVaultConfig({ ...full, VAULT_PREFIX: "vault" })).toThrow(/VAULT_PREFIX/);
    expect(() => parseVaultConfig({ ...full, VAULT_PREFIX: "/vault/" })).toThrow(/VAULT_PREFIX/);
  });

  it("is part of loadConfig and creates an S3 store", () => {
    const quiet = { warn() {} };
    expect(loadConfig({ NODE_ENV: "test" }, quiet).vault).toBeNull();
    const config = loadConfig({ NODE_ENV: "test", ...full }, quiet);
    expect(createVaultStore(config.vault)?.kind).toBe("s3");
    expect(createVaultStore(null)).toBeNull();
  });
});
