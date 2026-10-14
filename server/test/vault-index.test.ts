import { createHash } from "node:crypto";
import { get, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { gunzipSync } from "node:zlib";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { Express } from "express";
import request from "supertest";
import { afterEach, describe, expect, it } from "vitest";
import { LinkResolver, retargetLink, rewriteWikilinks } from "../src/vault/links.js";
import {
  PARSER_VERSION,
  extractFirstEmbed,
  extractLinks,
  extractSnippet,
  extractTasks,
  parseFrontmatter,
  parseNote,
} from "../src/vault/markdown.js";
import { MemoryVaultStore } from "../src/vault/memory.js";
import type { VaultFile } from "../src/vault/types.js";
import { AUTH, setup } from "./helpers.js";

/** Counts reads so tests can see which notes the index fetched. */
class CountingVaultStore extends MemoryVaultStore {
  readonly reads: string[] = [];
  override async read(path: string): Promise<VaultFile | null> {
    this.reads.push(path);
    return super.read(path);
  }
}

async function seed(store: MemoryVaultStore, files: Record<string, string | Buffer>) {
  let mtime = 1_760_000_000_000;
  for (const [path, body] of Object.entries(files)) {
    await store.write(path, Buffer.isBuffer(body) ? body : Buffer.from(body, "utf8"), {
      mtime: (mtime += 1000),
      contentType: "text/markdown",
    });
  }
}

function put(app: Express, path: string, body: string) {
  return request(app).put("/v1/vault/file").query({ path }).set(AUTH).set("Content-Type", "application/octet-stream").send(body);
}

/** GET /v1/vault/index without automatic decompression. */
function getRaw(app: Express, headers: Record<string, string> = {}) {
  return request(app)
    .get("/v1/vault/index")
    .set(AUTH)
    .set(headers)
    .buffer(true)
    .parse((res, done) => {
      const chunks: Buffer[] = [];
      res.on("data", (chunk: Buffer) => chunks.push(chunk));
      res.on("end", () => done(null, Buffer.concat(chunks)));
    });
}

describe("markdown parsing", () => {
  it("parses frontmatter lists, inline arrays, comma strings and quotes", () => {
    const { data, body } = parseFrontmatter(
      [
        "---",
        "aliases:",
        "  - 第一",
        '  - "Second One"',
        "tags: [a, '#b/c', \"d\"]",
        "alias: 'x, y'",
        "title: Hello: World",
        "empty:",
        "nested:",
        "  key: value",
        "localocr-notebook: \"nb-1\"",
        "---",
        "Body text",
      ].join("\n"),
    );
    expect(data.aliases).toEqual(["第一", "Second One"]);
    expect(data.tags).toEqual(["a", "#b/c", "d"]);
    expect(data.alias).toBe("x, y");
    expect(data.title).toBe("Hello: World");
    expect(data.empty).toBeNull();
    expect(data.nested).toBeNull();
    expect(data["localocr-notebook"]).toBe("nb-1");
    expect(body).toBe("Body text");

    expect(parseFrontmatter("no frontmatter\n---\n").data).toEqual({});
    expect(parseFrontmatter("---\n---\nbody").body).toBe("body");
    expect(parseFrontmatter("﻿---\r\ntags: x\r\n---\r\nbody").data).toEqual({ tags: "x" });
  });

  it("extracts note links like the app", () => {
    const text =
      "See [[Target]], [[target|again]], [[Folder/Other#Heading|alias]], [[Third^block]], ![[Embedded Note]] " +
      "![[photo.PNG|300]] [[doc.pdf]] [[board.canvas]] [[ ]] [[#Local heading]] [[Note v1.2]]";
    expect(extractLinks(text)).toEqual(["Target", "Folder/Other", "Third", "Embedded Note", "Note v1.2"]);
  });

  it("finds the first embed and tasks", () => {
    expect(extractFirstEmbed("text ![[img/a.png|200]] then ![](b.png)")).toBe("img/a.png");
    expect(extractFirstEmbed("![remote](https://x.test/a.png) ![local](<my photo.jpg>) ![[later.png]]")).toBe("my photo.jpg");
    expect(extractFirstEmbed("![](data:image/png;base64,xx) ![](pics/a%20b.png)")).toBe("pics/a b.png");
    expect(extractFirstEmbed("nothing [[here]]")).toBeNull();

    const tasks = extractTasks("- [ ] one\n  * [x] two\n+ [X] three\n- [] no\n-[ ] no\n1. [ ] no\n- [ ]\n");
    expect(tasks).toEqual([
      { text: "one", done: false },
      { text: "two", done: true },
      { text: "three", done: true },
    ]);
    expect(extractTasks("- [ ] t\n".repeat(250))).toHaveLength(200);
  });

  it("builds snippets from the first paragraph or list item", () => {
    expect(extractSnippet("# Title\n\n```js\ncode\n```\n![[a.png]] ![](b.png)\n\nFirst line\nsecond line\n\nNext")).toBe(
      "First line second line",
    );
    expect(extractSnippet("## H\n- [ ] task item\n- other")).toBe("task item");
    expect(extractSnippet("x".repeat(200))).toHaveLength(160);
    expect(extractSnippet("😀".repeat(170))).toBe("😀".repeat(160));
    expect(extractSnippet("---\n\n# only heading\n")).toBe("");
  });

  it("parses a whole note", () => {
    const note = parseNote(
      "Folder/My Note.md",
      "---\naliases: Alpha, \"Beta\"\ntags:\n  - '#project/x'\n  - todo\nlocalocr-notebook: abc\n---\n# Heading\nIntro [[Link]] ![[pic.png]]\n- [x] done\n",
    );
    expect(note).toMatchObject({
      title: "My Note",
      aliases: ["Alpha", "Beta"],
      tags: ["project/x", "todo"],
      links: ["Link"],
      firstEmbed: "pic.png",
      tasks: [{ text: "done", done: true }],
      snippet: "Intro [[Link]] ![[pic.png]]",
      notebook: "abc",
      allLinks: ["Link", "pic.png"],
    });
  });
});

describe("link resolution", () => {
  const resolver = new LinkResolver([
    { path: "B.md" },
    { path: "Deep/Er/B.md" },
    { path: "Projects/Plan.md", aliases: ["計畫"] },
    { path: "x/Projects/Plan.md" },
    { path: "img/a.png" },
  ]);

  it("resolves by path, then file name (shortest path), then alias, ignoring case", () => {
    expect(resolver.resolve("b")).toBe("B.md");
    expect(resolver.resolve("Deep/Er/B")).toBe("Deep/Er/B.md");
    expect(resolver.resolve("er/b")).toBe("Deep/Er/B.md");
    expect(resolver.resolve("plan")).toBe("Projects/Plan.md");
    expect(resolver.resolve("Projects/Plan.md")).toBe("Projects/Plan.md");
    expect(resolver.resolve("計畫")).toBe("Projects/Plan.md");
    expect(resolver.resolve("A.PNG")).toBe("img/a.png");
    expect(resolver.resolve("missing")).toBeNull();
  });

  it("rewrites link targets keeping embeds, headings, blocks and aliases", () => {
    const before = new LinkResolver([{ path: "Projects/Plan.md", aliases: ["計畫"] }, { path: "Other.md" }]);
    const after = new LinkResolver([{ path: "Archive/Plan 2026.md", aliases: ["計畫"] }, { path: "Other.md" }]);
    const move = { from: "Projects/Plan.md", to: "Archive/Plan 2026.md", before, after };
    const text = "[[Plan]] [[Projects/Plan#Goals|目標]] ![[Projects/Plan.md^b1]] [[計畫]] [[Other]] [[plan|別名]]";
    const { text: rewritten, count } = rewriteWikilinks(text, (target) => retargetLink(target, move));
    expect(rewritten).toBe(
      "[[Plan 2026]] [[Archive/Plan 2026#Goals|目標]] ![[Archive/Plan 2026.md^b1]] [[計畫]] [[Other]] [[Plan 2026|別名]]",
    );
    expect(count).toBe(4);

    // the new name is not unique: name-style links switch to the path
    const crowded = new LinkResolver([{ path: "Archive/Plan 2026.md" }, { path: "Plan 2026.md" }]);
    expect(retargetLink("Plan", { ...move, after: crowded })).toBe("Archive/Plan 2026");
    // same name in another folder: name-style links still resolve and stay untouched
    const renamedFolder = new LinkResolver([{ path: "Archive/Plan.md" }]);
    expect(retargetLink("Plan", { ...move, to: "Archive/Plan.md", after: renamedFolder })).toBeNull();
  });
});

describe("GET /v1/vault/index", () => {
  it("answers 503 without a vault and 401 without a key", async () => {
    const { app } = await setup();
    const res = await request(app).get("/v1/vault/index").set(AUTH).expect(503);
    expect(res.body.error.code).toBe("vault_not_configured");
    const configured = await setup({ vault: new MemoryVaultStore() });
    await request(configured.app).get("/v1/vault/index").expect(401);
  });

  it("indexes every note and lists other files, skipping dot folders", async () => {
    const store = new MemoryVaultStore();
    await seed(store, {
      "Inbox/Idea.md": "---\ntags: [idea]\naliases: [點子]\n---\n# Idea\nSee [[Plan]] and ![[img/sketch.png|200]]\n- [ ] follow up\n",
      "Projects/Plan.md": "Plan body [[Idea]]",
      "img/sketch.png": Buffer.from([0x89, 0x50, 0x4e, 0x47]),
      ".obsidian/app.json": "{}",
      "Notes/.hidden/secret.md": "x",
      ".trash/old.md": "old",
    });
    const { app } = await setup({ vault: store });
    const res = await request(app).get("/v1/vault/index").set(AUTH).expect(200);
    expect(res.headers["content-type"]).toMatch(/^application\/json/);
    expect(res.headers.etag).toMatch(/^"[0-9a-f]{40}"$/);
    expect(res.body.version).toBe(1);
    expect(res.body.notes).toEqual([
      {
        path: "Inbox/Idea.md",
        mtime: expect.any(Number),
        size: expect.any(Number),
        etag: expect.any(String),
        title: "Idea",
        aliases: ["點子"],
        tags: ["idea"],
        links: ["Plan"],
        firstEmbed: "img/sketch.png",
        tasks: [{ text: "follow up", done: false }],
        snippet: "See [[Plan]] and ![[img/sketch.png|200]]",
        notebook: null,
      },
      expect.objectContaining({ path: "Projects/Plan.md", title: "Plan", links: ["Idea"], snippet: "Plan body [[Idea]]" }),
    ]);
    expect(Object.keys(res.body.notes[0])).toEqual([
      "path", "mtime", "size", "etag", "title", "aliases", "tags", "links", "firstEmbed", "tasks", "snippet", "notebook",
    ]);
    expect(res.body.files).toEqual([{ path: "img/sketch.png", mtime: expect.any(Number), size: 4 }]);

    // ETag = sha1 of the sorted path+etag pairs and the parser version
    const entries = (await store.list("", { recursive: true })).items
      .filter((entry) => !entry.path.split("/").some((segment) => segment.startsWith(".")))
      .sort((a, b) => (a.path < b.path ? -1 : 1));
    const hash = createHash("sha1").update(`index:1;parser:${PARSER_VERSION}\n`);
    for (const entry of entries) hash.update(`${entry.path}\u0000${entry.etag}\n`);
    expect(res.headers.etag).toBe(`"${hash.digest("hex")}"`);
  });

  it("answers 304 for a matching If-None-Match and a new ETag after a change", async () => {
    const store = new MemoryVaultStore();
    await seed(store, { "a.md": "A" });
    const { app } = await setup({ vault: store });
    const first = await request(app).get("/v1/vault/index").set(AUTH).expect(200);
    const etag = first.headers.etag!;
    const cached = await request(app).get("/v1/vault/index").set(AUTH).set("If-None-Match", etag).expect(304);
    expect(cached.headers.etag).toBe(etag);
    expect(cached.text).toBe("");
    await request(app).get("/v1/vault/index").set(AUTH).set("If-None-Match", `W/${etag}, "other"`).expect(304);
    await request(app).get("/v1/vault/index").set(AUTH).set("If-None-Match", '"other"').expect(200);

    await put(app, "a.md", "A changed").expect(200);
    const changed = await request(app).get("/v1/vault/index").set(AUTH).set("If-None-Match", etag).expect(200);
    expect(changed.headers.etag).not.toBe(etag);
  });

  it("gzips the body when the client accepts gzip", async () => {
    const store = new MemoryVaultStore();
    await seed(store, { "a.md": "# A\n" + "lorem ipsum ".repeat(200) });
    const { app } = await setup({ vault: store });
    // raw bytes over a real socket (supertest would decompress)
    const server = app.listen(0, "127.0.0.1");
    await new Promise((resolve) => server.once("listening", resolve));
    const { port } = server.address() as AddressInfo;
    const zipped = await new Promise<{ headers: Record<string, unknown>; body: Buffer }>((resolve, reject) => {
      get({ host: "127.0.0.1", port, path: "/v1/vault/index", headers: { ...AUTH, "Accept-Encoding": "gzip, deflate" } }, (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk: Buffer) => chunks.push(chunk));
        res.on("end", () => resolve({ headers: res.headers, body: Buffer.concat(chunks) }));
      }).on("error", reject);
    });
    await new Promise((resolve) => server.close(resolve));
    expect(zipped.headers["content-encoding"]).toBe("gzip");
    expect(zipped.headers.vary).toMatch(/Accept-Encoding/);
    expect(zipped.body.subarray(0, 2)).toEqual(Buffer.from([0x1f, 0x8b]));
    const body = JSON.parse(gunzipSync(zipped.body).toString("utf8"));
    expect(body.notes[0].path).toBe("a.md");

    const plain = await getRaw(app, { "Accept-Encoding": "identity" }).expect(200);
    expect(plain.headers["content-encoding"]).toBeUndefined();
    expect(JSON.parse((plain.body as Buffer).toString("utf8"))).toEqual(body);
    const refused = await getRaw(app, { "Accept-Encoding": "gzip;q=0" }).expect(200);
    expect(refused.headers["content-encoding"]).toBeUndefined();
  });

  it("re-reads only notes whose etag changed", async () => {
    const store = new CountingVaultStore();
    await seed(store, { "a.md": "A [[b]]", "b.md": "B", "c.md": "C", "img.png": "png" });
    const { app } = await setup({ vault: store });
    await request(app).get("/v1/vault/index").set(AUTH).expect(200);
    expect(store.reads.sort()).toEqual(["a.md", "b.md", "c.md"]);

    store.reads.length = 0;
    await put(app, "b.md", "B now links [[c]]").expect(200);
    await put(app, "d.md", "D").expect(201);
    store.reads.length = 0;
    const res = await request(app).get("/v1/vault/index").set(AUTH).expect(200);
    expect(store.reads.sort()).toEqual(["b.md", "d.md"]);
    expect(res.body.notes.find((note: { path: string }) => note.path === "b.md").links).toEqual(["c"]);

    // within 5 s and without changes through the server, the built index is reused
    store.reads.length = 0;
    await request(app).get("/v1/vault/index").set(AUTH).expect(200);
    expect(store.reads).toEqual([]);
  });
});

describe("MCP vault_links", () => {
  const servers: Server[] = [];
  const clients: Client[] = [];
  afterEach(async () => {
    await Promise.all(clients.splice(0).map((client) => client.close()));
    await Promise.all(servers.splice(0).map((server) => new Promise((resolve) => server.close(resolve))));
  });

  it("returns resolved outgoing links and backlinks", async () => {
    const store = new MemoryVaultStore();
    await seed(store, {
      "Home.md": "[[B]] [[deep/b]] [[alpha|A]] ![[pic.png]] [[Missing]] [[Home#top]]",
      "B.md": "back to [[home]]",
      "Deep/B.md": "nothing",
      "Notes/Alpha Note.md": "---\naliases: [Alpha]\n---\n[[Home]]",
      "pic.png": "png",
      ".trash/Old.md": "[[Home]]",
    });
    const { app } = await setup({ vault: store });
    const server = app.listen(0, "127.0.0.1");
    servers.push(server);
    await new Promise((resolve) => server.once("listening", resolve));
    const { port } = server.address() as AddressInfo;
    const client = new Client({ name: "test", version: "1.0.0" });
    await client.connect(new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`), { requestInit: { headers: AUTH } }));
    clients.push(client);

    const result = await client.callTool({ name: "vault_links", arguments: { path: "Home.md" } });
    expect(result.isError).toBeFalsy();
    const content = result.content as { text: string }[];
    expect(JSON.parse(content[0]!.text)).toEqual({
      path: "Home.md",
      outgoing: ["B.md", "Deep/B.md", "Notes/Alpha Note.md", "pic.png"],
      backlinks: ["B.md", "Notes/Alpha Note.md"],
    });

    // a link name works too; unknown files are not_found
    const byName = await client.callTool({ name: "vault_links", arguments: { path: "alpha note" } });
    expect(JSON.parse((byName.content as { text: string }[])[0]!.text).path).toBe("Notes/Alpha Note.md");
    const missing = await client.callTool({ name: "vault_links", arguments: { path: "Nope.md" } });
    expect(missing.isError).toBe(true);
    expect(JSON.parse((missing.content as { text: string }[])[0]!.text).error.code).toBe("not_found");
  });
});
