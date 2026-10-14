import { createHash } from "node:crypto";
import type { Express } from "express";
import request from "supertest";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MemoryStore } from "../src/store/memory.js";
import {
  ObsidianPluginService,
  PLUGIN_RELEASES_URL,
  parseGitHubReleases,
  schedulePluginMirror,
  type FetchFn,
  type PluginMirrorResult,
} from "../src/services/obsidian-plugin.js";
import { MemoryVaultStore } from "../src/vault/memory.js";
import { AUTH, setup } from "./helpers.js";

const MAIN_JS = `/* LocalOCR Sync */\n"use strict";\n${"var x = 1;\n".repeat(200)}module.exports = __toCommonJS(main_exports);\n`;
const manifestFor = (version: string, extra: Record<string, unknown> = {}) =>
  `${JSON.stringify({ id: "localocr-sync", name: "LocalOCR Sync", version, minAppVersion: "1.5.0", ...extra }, null, "\t")}\n`;
const sha = (body: string | Buffer) => createHash("sha256").update(body).digest("hex");
const NOW = Date.parse("2026-10-14T08:00:00Z");
const assetUrl = (tag: string, name: string) => `https://github.com/andyyyyang/iOS-APP/releases/download/${tag}/${name}`;

interface ReleaseOptions {
  tag?: string;
  draft?: boolean;
  prerelease?: boolean;
  files?: Record<string, string>;
  /** Digest per file name; default: the file's real sha256. null = GitHub reports none. */
  digests?: Record<string, string | null>;
}

function release(version: string, opts: ReleaseOptions = {}) {
  const tag = opts.tag ?? `obsidian-plugin-${version}`;
  const files = opts.files ?? { "main.js": MAIN_JS, "manifest.json": manifestFor(version) };
  return {
    tag_name: tag,
    draft: opts.draft ?? false,
    prerelease: opts.prerelease ?? false,
    body: `\n- ${version} 第一項\n- 第二項\n`,
    published_at: "2026-10-14T00:00:00Z",
    html_url: `https://github.com/andyyyyang/iOS-APP/releases/tag/${tag}`,
    assets: Object.entries(files).map(([name, text]) => {
      const digest = opts.digests && name in opts.digests ? opts.digests[name] : `sha256:${sha(text)}`;
      return { name, size: Buffer.byteLength(text), digest, browser_download_url: assetUrl(tag, name) };
    }),
  };
}

type GitHubRelease = ReturnType<typeof release>;

/**
 * Fake GitHub: the releases listing (read at request time, so tests can change it) plus every asset by URL:
 * main.js / the release's manifest by default, `contents` overrides, `missing` answers 404.
 */
function fakeGitHub(
  releases: GitHubRelease[],
  { contents = {}, missing = [], listing }: { contents?: Record<string, string>; missing?: string[]; listing?: () => Response | Promise<Response> } = {},
) {
  const requests: { url: string; headers: Record<string, string> }[] = [];
  const byUrl = new Map<string, string>();
  for (const r of releases) {
    for (const asset of r.assets) {
      const version = r.tag_name.replace("obsidian-plugin-", "");
      byUrl.set(asset.browser_download_url, asset.name === "main.js" ? MAIN_JS : manifestFor(version));
    }
  }
  for (const [url, text] of Object.entries(contents)) byUrl.set(url, text);
  for (const url of missing) byUrl.delete(url);
  const fetch: FetchFn = async (url, init) => {
    requests.push({ url, headers: init.headers });
    if (url === PLUGIN_RELEASES_URL) {
      if (listing) return listing();
      return new Response(JSON.stringify(releases), { headers: { "Content-Type": "application/json" } });
    }
    const text = byUrl.get(url);
    return text === undefined ? new Response("Not Found", { status: 404 }) : new Response(text);
  };
  const downloads = () => requests.filter((r) => r.url !== PLUGIN_RELEASES_URL).map((r) => r.url);
  return { fetch, requests, downloads, byUrl };
}

const logger = () => ({ info: vi.fn(), warn: vi.fn(), error: vi.fn() });

async function mirrorApp(
  releases: GitHubRelease[],
  options: { contents?: Record<string, string>; missing?: string[]; publicUrl?: string; githubToken?: string } = {},
) {
  const github = fakeGitHub(releases, { contents: options.contents, missing: options.missing });
  const vault = new MemoryVaultStore("vault/");
  const log = logger();
  const { app, store } = await setup({
    vault,
    publicUrl: options.publicUrl,
    now: () => NOW,
    pluginMirror: { fetch: github.fetch, githubToken: options.githubToken, logger: log },
  });
  return { app, store, vault, github, log };
}

const refresh = (app: Express) => request(app).post("/v1/obsidian-plugin/refresh").set(AUTH);

/** GET a plugin file as raw bytes whatever its Content-Type. */
function getRaw(app: Express, path: string) {
  return request(app)
    .get(path)
    .buffer(true)
    .parse((res, done) => {
      const chunks: Buffer[] = [];
      res.on("data", (chunk: Buffer) => chunks.push(chunk));
      res.on("end", () => done(null, Buffer.concat(chunks)));
    });
}

describe("Obsidian plugin mirror", () => {
  it("answers 503 vault_not_configured without a bucket", async () => {
    const { app } = await setup({ pluginMirror: { fetch: fakeGitHub([release("1.3.0")]).fetch } });
    const responses = [
      await request(app).get("/obsidian-plugin/latest.json"),
      await request(app).get("/obsidian-plugin/latest/main.js"),
      await request(app).get("/obsidian-plugin/releases/1.3.0/main.js"),
      await refresh(app),
    ];
    for (const res of responses) {
      expect(res.status).toBe(503);
      expect(res.body.error.code).toBe("vault_not_configured");
    }
  });

  it("answers 404 before anything is mirrored", async () => {
    const { app } = await mirrorApp([]);
    const res = await request(app).get("/obsidian-plugin/latest.json").expect(404);
    expect(res.body).toEqual({ error: { code: "not_found", message: "No Obsidian plugin release has been mirrored yet" } });
    await request(app).get("/obsidian-plugin/latest/main.js").expect(404);
  });

  it("mirrors published plugin releases into a hidden bucket folder and records their hashes", async () => {
    const { app, store, vault, github } = await mirrorApp([
      release("1.2.0"),
      release("1.3.0"),
      release("2.0.0", { draft: true }),
      release("1.4.0", { prerelease: true }),
      release("9.9.9", { tag: "testflight-9.9.9" }),
      release("1.2.1", { files: { "main.js": MAIN_JS } }),
    ]);
    const res = await refresh(app).expect(200);
    expect(res.body).toEqual({ latest: "1.3.0", mirrored: ["1.3.0", "1.2.0"], repaired: [], failed: [] });

    const main = await vault.read(".localocr/obsidian-plugin/1.3.0/main.js");
    expect(main?.body.toString()).toBe(MAIN_JS);
    expect(main?.mtime).toBe(NOW);
    expect((await vault.read(".localocr/obsidian-plugin/1.2.0/manifest.json"))?.body.toString()).toBe(manifestFor("1.2.0"));
    expect(await store.getPluginRelease("1.3.0")).toEqual({
      version: "1.3.0",
      minAppVersion: "1.5.0",
      notes: "- 1.3.0 第一項\n- 第二項",
      publishedAt: "2026-10-14T00:00:00.000Z",
      files: {
        "main.js": { sha256: sha(MAIN_JS), size: Buffer.byteLength(MAIN_JS) },
        "manifest.json": { sha256: sha(manifestFor("1.3.0")), size: Buffer.byteLength(manifestFor("1.3.0")) },
      },
      mirroredAt: "2026-10-14T08:00:00.000Z",
    });

    // GitHub API headers; no token configured
    const listing = github.requests.find((r) => r.url === PLUGIN_RELEASES_URL)!;
    expect(listing.headers).toMatchObject({ Accept: "application/vnd.github+json", "User-Agent": "localocr-server" });
    expect(listing.headers.Authorization).toBeUndefined();

    // A second run downloads nothing: both versions are recorded and the newest one's bucket files still match
    const before = github.downloads().length;
    expect((await refresh(app).expect(200)).body).toEqual({ latest: "1.3.0", mirrored: [], repaired: [], failed: [] });
    expect(github.downloads()).toHaveLength(before);
  });

  it("serves latest.json with absolute URLs of the versioned files", async () => {
    const { app } = await mirrorApp([release("1.3.0"), release("1.2.0")], { publicUrl: "https://ocr.example.com" });
    await refresh(app).expect(200);
    const res = await request(app).get("/obsidian-plugin/latest.json").expect(200);
    expect(res.headers["cache-control"]).toBe("no-cache");
    expect(res.body).toEqual({
      version: "1.3.0",
      minAppVersion: "1.5.0",
      notes: "- 1.3.0 第一項\n- 第二項",
      publishedAt: "2026-10-14T00:00:00.000Z",
      files: {
        "main.js": {
          sha256: sha(MAIN_JS),
          size: Buffer.byteLength(MAIN_JS),
          url: "https://ocr.example.com/obsidian-plugin/releases/1.3.0/main.js",
        },
        "manifest.json": {
          sha256: sha(manifestFor("1.3.0")),
          size: Buffer.byteLength(manifestFor("1.3.0")),
          url: "https://ocr.example.com/obsidian-plugin/releases/1.3.0/manifest.json",
        },
      },
    });
  });

  it("derives file URLs from the request without PUBLIC_URL", async () => {
    const { app } = await mirrorApp([release("1.3.0")]);
    await refresh(app).expect(200);
    const res = await request(app)
      .get("/obsidian-plugin/latest.json")
      .set({ Host: "localocr.up.railway.app", "X-Forwarded-Proto": "https" })
      .expect(200);
    expect(res.body.files["main.js"].url).toBe("https://localocr.up.railway.app/obsidian-plugin/releases/1.3.0/main.js");
  });

  it("serves versioned and latest files without auth, with Content-Type, ETag and caching", async () => {
    const { app } = await mirrorApp([release("1.3.0"), release("1.2.0")]);
    await refresh(app).expect(200);

    const main = await getRaw(app, "/obsidian-plugin/releases/1.2.0/main.js").expect(200);
    expect(main.body.toString()).toBe(MAIN_JS);
    expect(main.headers["content-type"]).toBe("text/javascript; charset=utf-8");
    expect(main.headers.etag).toBe(`"${sha(MAIN_JS)}"`);
    expect(main.headers["cache-control"]).toBe("public, max-age=31536000, immutable");
    expect(main.headers["content-disposition"]).toBe('attachment; filename="main.js"');
    expect(main.headers["x-content-type-options"]).toBe("nosniff");

    const manifest = await getRaw(app, "/obsidian-plugin/releases/1.2.0/manifest.json").expect(200);
    expect(manifest.headers["content-type"]).toBe("application/json");
    expect(manifest.body.toString()).toBe(manifestFor("1.2.0"));

    const latest = await getRaw(app, "/obsidian-plugin/latest/manifest.json").expect(200);
    expect(JSON.parse(latest.body.toString()).version).toBe("1.3.0");
    expect(latest.headers["cache-control"]).toBe("no-cache");
    expect(latest.headers["content-disposition"]).toBe('attachment; filename="manifest.json"');
    await getRaw(app, "/obsidian-plugin/latest/main.js").expect(200);

    await request(app).get("/obsidian-plugin/releases/1.2.0/main.js").set("If-None-Match", `"${sha(MAIN_JS)}"`).expect(304);

    for (const path of [
      "/obsidian-plugin/releases/1.2.0/styles.css",
      "/obsidian-plugin/releases/1.9.0/main.js",
      "/obsidian-plugin/releases/latest/main.js",
      "/obsidian-plugin/releases/..%2F..%2Fsecret/main.js",
      "/obsidian-plugin/latest/data.json",
    ]) {
      const res = await request(app).get(path);
      expect(res.status, path).toBe(404);
      expect(res.body.error.code, path).toBe("not_found");
    }
  });

  it("refuses to serve bucket files that no longer match the database, and the next mirror restores them", async () => {
    const { app, vault, log } = await mirrorApp([release("1.3.0"), release("1.2.0")]);
    await refresh(app).expect(200);

    // Anyone with the bucket keys (every device's Remotely Save) could do this
    await vault.write(".localocr/obsidian-plugin/1.3.0/main.js", Buffer.from(MAIN_JS.replace("var x", "evil")), {
      mtime: 1,
      contentType: "text/javascript",
    });
    for (const path of ["/obsidian-plugin/latest/main.js", "/obsidian-plugin/releases/1.3.0/main.js"]) {
      const res = await request(app).get(path).expect(502);
      expect(res.body.error).toEqual({
        code: "integrity_error",
        message: "main.js of 1.3.0 in storage does not match its recorded SHA-256",
      });
    }
    expect(log.error).toHaveBeenCalledWith(expect.stringContaining("does not match its recorded SHA-256"));

    await vault.delete(".localocr/obsidian-plugin/1.3.0/manifest.json");
    const missing = await request(app).get("/obsidian-plugin/latest/manifest.json").expect(502);
    expect(missing.body.error).toEqual({ code: "integrity_error", message: "manifest.json of 1.3.0 is missing from storage" });
    // latest.json reads only the database
    await request(app).get("/obsidian-plugin/latest.json").expect(200);

    const repaired = await refresh(app).expect(200);
    expect(repaired.body).toEqual({ latest: "1.3.0", mirrored: [], repaired: ["1.3.0"], failed: [] });
    expect((await getRaw(app, "/obsidian-plugin/latest/main.js").expect(200)).body.toString()).toBe(MAIN_JS);
    expect((await getRaw(app, "/obsidian-plugin/latest/manifest.json").expect(200)).body.toString()).toBe(manifestFor("1.3.0"));
  });

  it("does not restore from a GitHub file that changed after mirroring", async () => {
    const releases = [release("1.3.0")];
    const { app, vault, github } = await mirrorApp(releases);
    await refresh(app).expect(200);
    await vault.delete(".localocr/obsidian-plugin/1.3.0/main.js");

    // The release asset was replaced on GitHub (with a matching digest): a recorded version never changes
    const changed = MAIN_JS.replace("var x", "var y");
    releases.splice(0, 1, release("1.3.0", { files: { "main.js": changed, "manifest.json": manifestFor("1.3.0") } }));
    github.byUrl.set(assetUrl("obsidian-plugin-1.3.0", "main.js"), changed);
    const res = await refresh(app).expect(200);
    expect(res.body).toEqual({
      latest: "1.3.0",
      mirrored: [],
      repaired: [],
      failed: [{ version: "1.3.0", error: "main.js on GitHub no longer matches the recorded SHA-256" }],
    });
    await request(app).get("/obsidian-plugin/latest/main.js").expect(502);
  });

  it("skips releases that fail verification and reports why", async () => {
    const { app, vault, log } = await mirrorApp(
      [
        release("1.5.0"),
        release("1.4.0", { files: { "main.js": MAIN_JS, "manifest.json": manifestFor("1.4.0", { id: "other-plugin" }) } }),
        release("1.3.0", { files: { "main.js": MAIN_JS, "manifest.json": manifestFor("1.2.9") } }),
        release("1.2.0", { files: { "main.js": MAIN_JS, "manifest.json": "<html>" } }),
        release("1.1.0"),
        // No digest from GitHub: the manifest checks still apply
        release("1.0.0", { digests: { "main.js": null, "manifest.json": null } }),
      ],
      {
        contents: {
          [assetUrl("obsidian-plugin-1.5.0", "main.js")]: MAIN_JS.replace("var x", "var y"),
          [assetUrl("obsidian-plugin-1.4.0", "manifest.json")]: manifestFor("1.4.0", { id: "other-plugin" }),
          [assetUrl("obsidian-plugin-1.3.0", "manifest.json")]: manifestFor("1.2.9"),
          [assetUrl("obsidian-plugin-1.2.0", "manifest.json")]: "<html>",
        },
        missing: [assetUrl("obsidian-plugin-1.1.0", "main.js")],
      },
    );
    const res = await refresh(app).expect(200);
    expect(res.body).toEqual({
      latest: "1.0.0",
      mirrored: ["1.0.0"],
      repaired: [],
      failed: [
        { version: "1.5.0", error: "main.js does not match GitHub's SHA-256 digest" },
        { version: "1.4.0", error: 'manifest.json id is "other-plugin", expected "localocr-sync"' },
        { version: "1.3.0", error: 'manifest.json version is "1.2.9", expected "1.3.0" (the tag)' },
        { version: "1.2.0", error: "manifest.json is not a JSON object" },
        { version: "1.1.0", error: "downloading main.js failed: HTTP 404" },
      ],
    });
    expect(log.error).toHaveBeenCalledWith("[obsidian-plugin] mirroring 1.5.0 failed: main.js does not match GitHub's SHA-256 digest");
    expect((await vault.list(".localocr/", { recursive: true })).items.map((item) => item.path)).toEqual([
      ".localocr/obsidian-plugin/1.0.0/main.js",
      ".localocr/obsidian-plugin/1.0.0/manifest.json",
    ]);
  });

  it("answers 502 github_unavailable when the releases listing fails", async () => {
    const cases: [() => Response | Promise<Response>, string][] = [
      [() => new Response("{}", { status: 403 }), "GitHub releases: HTTP 403"],
      [() => new Response("not json"), "GitHub releases: the listing is not valid JSON"],
      [() => new Response(JSON.stringify({ message: "x" })), "GitHub releases: the listing is not an array"],
      [
        () => {
          throw new TypeError("fetch failed");
        },
        "GitHub releases: request failed: fetch failed",
      ],
    ];
    for (const [listing, message] of cases) {
      const { fetch } = fakeGitHub([], { listing });
      const { app } = await setup({ vault: new MemoryVaultStore(), pluginMirror: { fetch } });
      const res = await refresh(app).expect(502);
      expect(res.body.error).toEqual({ code: "github_unavailable", message });
    }
  });

  it("sends GITHUB_TOKEN only to the GitHub API", async () => {
    const { app, github } = await mirrorApp([release("1.3.0")], { githubToken: "ghp_test_token" });
    await refresh(app).expect(200);
    const listing = github.requests.filter((r) => r.url === PLUGIN_RELEASES_URL);
    expect(listing.map((r) => r.headers.Authorization)).toEqual(["Bearer ghp_test_token"]);
    const assets = github.requests.filter((r) => r.url !== PLUGIN_RELEASES_URL);
    expect(assets).toHaveLength(2);
    for (const asset of assets) expect(asset.headers.Authorization).toBeUndefined();
  });

  it("requires an API key to refresh but not to download", async () => {
    const { app } = await mirrorApp([release("1.3.0")]);
    const res = await request(app).post("/v1/obsidian-plugin/refresh").expect(401);
    expect(res.body.error.code).toBe("unauthorized");
    await refresh(app).expect(200);
    await request(app).get("/obsidian-plugin/latest.json").expect(200);
    await request(app).get("/obsidian-plugin/latest/main.js").expect(200);
  });

  it("shares one run between concurrent refreshes", async () => {
    let release130!: () => void;
    const gate = new Promise<void>((resolve) => (release130 = resolve));
    const github = fakeGitHub([release("1.3.0")]);
    const fetch: FetchFn = async (url, init) => {
      if (url === PLUGIN_RELEASES_URL) await gate;
      return github.fetch(url, init);
    };
    const service = new ObsidianPluginService({ store: new MemoryStore(), vault: new MemoryVaultStore(), fetch, logger: logger() });
    const first = service.refresh();
    const second = service.refresh();
    release130();
    const [a, b] = await Promise.all([first, second]);
    expect(a).toEqual({ latest: "1.3.0", mirrored: ["1.3.0"], repaired: [], failed: [] });
    expect(b).toBe(a);
    expect(github.requests.filter((r) => r.url === PLUGIN_RELEASES_URL)).toHaveLength(1);
    // the next call starts a new run
    expect((await service.refresh()).mirrored).toEqual([]);
  });

  it("keeps mirrored files out of vault search", async () => {
    const { app } = await mirrorApp([release("1.3.0")]);
    await refresh(app).expect(200);
    const search = await request(app).get("/v1/vault/search").query({ q: "localocr-sync" }).set(AUTH).expect(200);
    expect(search.body.items).toEqual([]);
  });

  it("describes the endpoints in OpenAPI", async () => {
    const { app } = await setup();
    const res = await request(app).get("/v1/openapi.json").set(AUTH).expect(200);
    for (const path of [
      "/obsidian-plugin/latest.json",
      "/obsidian-plugin/latest/{file}",
      "/obsidian-plugin/releases/{version}/{file}",
      "/v1/obsidian-plugin/refresh",
    ]) {
      expect(res.body.paths[path], path).toBeDefined();
    }
    expect(res.body.paths["/obsidian-plugin/latest.json"].get.security).toEqual([]);
    expect(res.body.components.schemas.PluginRelease).toBeDefined();
    expect(res.body.components.schemas.PluginMirrorResult).toBeDefined();
  });
});

describe("plugin release records", () => {
  it("are inserted once and read back (memory, or Postgres with TEST_DATABASE_URL)", async () => {
    const { store } = await setup();
    const record = {
      version: "1.3.0",
      minAppVersion: "1.5.0",
      notes: "- 新功能",
      publishedAt: "2026-10-14T00:00:00.000Z",
      files: { "main.js": { sha256: sha("a"), size: 1 }, "manifest.json": { sha256: sha("b"), size: 1 } },
      mirroredAt: "2026-10-14T08:00:00.000Z",
    };
    expect(await store.listPluginReleases()).toEqual([]);
    expect(await store.insertPluginRelease(record)).toBe(true);
    expect(await store.insertPluginRelease({ ...record, notes: "changed" })).toBe(false);
    expect(await store.getPluginRelease("1.3.0")).toEqual(record);
    expect(await store.getPluginRelease("1.2.0")).toBeNull();
    expect(await store.listPluginReleases()).toEqual([record]);
  });
});

describe("parseGitHubReleases", () => {
  it("keeps published plugin releases with both files, newest first, and reads GitHub's digests", () => {
    const list = parseGitHubReleases([
      release("1.2.0"),
      release("1.10.0"),
      release("1.11.0", { tag: "obsidian-plugin-1.11" }),
      release("1.9.0", { digests: { "main.js": "md5:abc" } }),
      { tag_name: "obsidian-plugin-1.12.0", assets: "nope" },
      null,
    ]);
    expect(list.map((r) => r.version)).toEqual(["1.10.0", "1.9.0", "1.2.0"]);
    expect(list[0]!.assets["main.js"]).toEqual({ url: assetUrl("obsidian-plugin-1.10.0", "main.js"), sha256: sha(MAIN_JS) });
    expect(list[1]!.assets["main.js"].sha256).toBeNull();
  });
});

describe("schedulePluginMirror", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("mirrors after the startup delay, then every interval, and only logs failures", async () => {
    vi.useFakeTimers();
    const result: PluginMirrorResult = { latest: "1.3.0", mirrored: [], repaired: [], failed: [] };
    const refreshMock = vi
      .fn<() => Promise<PluginMirrorResult>>()
      .mockResolvedValueOnce(result)
      .mockRejectedValueOnce(new Error("GitHub releases: HTTP 500"))
      .mockResolvedValue(result);
    const log = { error: vi.fn() };
    const stop = schedulePluginMirror({ refresh: refreshMock }, { delayMs: 15_000, intervalMs: 30 * 60_000, logger: log });

    await vi.advanceTimersByTimeAsync(14_999);
    expect(refreshMock).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(refreshMock).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(30 * 60_000 - 15_000);
    expect(refreshMock).toHaveBeenCalledTimes(2);
    expect(log.error).toHaveBeenCalledWith("[obsidian-plugin] mirror failed: GitHub releases: HTTP 500");

    stop();
    await vi.advanceTimersByTimeAsync(2 * 30 * 60_000);
    expect(refreshMock).toHaveBeenCalledTimes(2);
  });
});
