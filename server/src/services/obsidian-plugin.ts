import { createHash } from "node:crypto";
import { AppError, notFound } from "../errors.js";
import type { Store } from "../store/types.js";
import { PLUGIN_FILES, type PluginFileName, type PluginRelease } from "../types.js";
import { VaultStorageError, type VaultStore } from "../vault/types.js";

// Online updates for the LocalOCR Sync Obsidian plugin come from this server, not from GitHub directly:
// CI publishes each version as the GitHub release "obsidian-plugin-<version>" (.github/workflows/obsidian-plugin-release.yml),
// the server mirrors its files into the vault bucket and serves them at /obsidian-plugin (http/routes/obsidian-plugin.ts).

/** Releases listing of the repository CI publishes the plugin to (newest first; plugin and app releases mixed). */
export const PLUGIN_RELEASES_URL = "https://api.github.com/repos/andyyyyang/iOS-APP/releases?per_page=50";
export const PLUGIN_TAG_PREFIX = "obsidian-plugin-";
export const PLUGIN_ID = "localocr-sync";
/**
 * Bucket folder (inside VAULT_PREFIX) of the mirrored files: .localocr/obsidian-plugin/<version>/main.js.
 * Remotely Save and the LocalOCR app skip dot folders, so it never shows up in anyone's vault.
 */
export const PLUGIN_FOLDER = ".localocr/obsidian-plugin/";
export const PLUGIN_CONTENT_TYPES: Record<PluginFileName, string> = {
  "main.js": "text/javascript; charset=utf-8",
  "manifest.json": "application/json",
};
/** The first mirror runs this long after startup, then every PLUGIN_MIRROR_INTERVAL_MS. */
export const PLUGIN_MIRROR_DELAY_MS = 15_000;
export const PLUGIN_MIRROR_INTERVAL_MS = 30 * 60 * 1000;

const MAX_ASSET_BYTES = 20 * 1024 * 1024;
const FETCH_TIMEOUT_MS = 30_000;
const USER_AGENT = "localocr-server";
const VERSION_PATTERN = /^(\d+)\.(\d+)\.(\d+)$/;

/** The part of fetch() the mirror uses, so tests can inject a fake GitHub. */
export type FetchFn = (url: string, init: { headers: Record<string, string>; signal: AbortSignal }) => Promise<Response>;

type Logger = Pick<Console, "info" | "warn" | "error">;

export interface GitHubAsset {
  url: string;
  /** Lowercase hex from GitHub's "sha256:<hex>" digest; null when GitHub reports none. */
  sha256: string | null;
}

/** A published plugin release in the GitHub listing that has both files. */
export interface GitHubPluginRelease {
  version: string;
  notes: string;
  publishedAt: string | null;
  assets: Record<PluginFileName, GitHubAsset>;
}

export interface PluginMirrorResult {
  /** The newest mirrored version after this run; null when there is none. */
  latest: string | null;
  /** Versions mirrored by this run. */
  mirrored: string[];
  /** Versions whose bucket files no longer matched their recorded SHA-256 and were downloaded again. */
  repaired: string[];
  failed: { version: string; error: string }[];
}

/** A file read back from the bucket and checked against the release record. */
export interface PluginFile {
  release: PluginRelease;
  name: PluginFileName;
  body: Buffer;
  sha256: string;
  contentType: string;
}

/** GET /obsidian-plugin/latest.json */
export interface PluginReleaseJson {
  version: string;
  minAppVersion: string;
  notes: string;
  publishedAt: string;
  files: Record<PluginFileName, { sha256: string; size: number; url: string }>;
}

export const sha256Hex = (body: Buffer) => createHash("sha256").update(body).digest("hex");

const pluginPath = (version: string, name: PluginFileName) => `${PLUGIN_FOLDER}${version}/${name}`;

const isPluginFile = (name: string): name is PluginFileName => (PLUGIN_FILES as readonly string[]).includes(name);

const message = (error: unknown) => (error instanceof Error ? error.message : String(error));

/** Negative when a < b, 0 when equal, positive when a > b (both x.y.z). */
export function compareVersions(a: string, b: string): number {
  const pa = (VERSION_PATTERN.exec(a) ?? []).slice(1).map(Number);
  const pb = (VERSION_PATTERN.exec(b) ?? []).slice(1).map(Number);
  for (let i = 0; i < 3; i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (diff) return diff;
  }
  return 0;
}

const newest = (releases: PluginRelease[]) =>
  releases.reduce<PluginRelease | null>((best, r) => (!best || compareVersions(r.version, best.version) > 0 ? r : best), null);

const notConfigured = () =>
  new AppError(503, "vault_not_configured", "Vault storage is not configured (set VAULT_S3_* variables)");

const githubUnavailable = (detail: string) => new AppError(502, "github_unavailable", `GitHub releases: ${detail}`);

const integrityError = (detail: string) => new AppError(502, "integrity_error", detail);

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

const str = (value: unknown) => (typeof value === "string" ? value : "");

/** Published plugin releases in a GitHub releases listing; drafts, pre-releases, other tags and releases missing a file are skipped. */
export function parseGitHubReleases(json: unknown): GitHubPluginRelease[] {
  if (!Array.isArray(json)) throw githubUnavailable("the listing is not an array");
  const releases: GitHubPluginRelease[] = [];
  for (const item of json) {
    const release = asRecord(item);
    if (!release || release.draft === true || release.prerelease === true) continue;
    const tag = str(release.tag_name);
    const version = tag.slice(PLUGIN_TAG_PREFIX.length);
    if (!tag.startsWith(PLUGIN_TAG_PREFIX) || !VERSION_PATTERN.test(version)) continue;
    const assets: Partial<Record<PluginFileName, GitHubAsset>> = {};
    for (const raw of Array.isArray(release.assets) ? release.assets : []) {
      const asset = asRecord(raw);
      const name = str(asset?.name);
      const url = str(asset?.browser_download_url);
      if (!isPluginFile(name) || !url.startsWith("https://")) continue;
      const digest = /^sha256:([0-9a-f]{64})$/i.exec(str(asset?.digest));
      assets[name] = { url, sha256: digest?.[1]?.toLowerCase() ?? null };
    }
    if (!assets["main.js"] || !assets["manifest.json"]) continue;
    releases.push({
      version,
      notes: str(release.body).trim(),
      publishedAt: str(release.published_at) || null,
      assets: assets as Record<PluginFileName, GitHubAsset>,
    });
  }
  return releases.sort((a, b) => compareVersions(b.version, a.version));
}

/** Checks a downloaded manifest.json: the plugin id and the release's version. Returns its minAppVersion. */
export function checkManifest(body: Buffer, version: string): { minAppVersion: string } {
  let manifest: Record<string, unknown> | null;
  try {
    manifest = asRecord(JSON.parse(body.toString("utf8")));
  } catch {
    manifest = null;
  }
  if (!manifest) throw new Error("manifest.json is not a JSON object");
  if (manifest.id !== PLUGIN_ID) throw new Error(`manifest.json id is ${JSON.stringify(manifest.id)}, expected "${PLUGIN_ID}"`);
  if (manifest.version !== version) {
    throw new Error(`manifest.json version is ${JSON.stringify(manifest.version)}, expected "${version}" (the tag)`);
  }
  return { minAppVersion: str(manifest.minAppVersion) };
}

/** latest.json: the release plus absolute URLs of its versioned files under `baseUrl`. */
export function releaseJson(release: PluginRelease, baseUrl: string): PluginReleaseJson {
  const file = (name: PluginFileName) => ({
    ...release.files[name],
    url: `${baseUrl}/obsidian-plugin/releases/${release.version}/${name}`,
  });
  return {
    version: release.version,
    minAppVersion: release.minAppVersion,
    notes: release.notes,
    publishedAt: release.publishedAt,
    files: { "main.js": file("main.js"), "manifest.json": file("manifest.json") },
  };
}

export interface ObsidianPluginServiceOptions {
  store: Store;
  /** The vault bucket the files are mirrored into; null when VAULT_S3_* is not configured (everything answers 503). */
  vault: VaultStore | null;
  fetch?: FetchFn;
  /** Sent only to the GitHub API (raises its rate limit). Never logged. */
  githubToken?: string;
  /** Clock in milliseconds (mirroredAt, the bucket files' mtime). */
  now?: () => number;
  logger?: Logger;
}

/**
 * Mirrors LocalOCR Sync releases from GitHub into the vault bucket and serves them back.
 * Trust: the release record (version, minAppVersion, notes, SHA-256 and size per file) lives in the database;
 * the bucket is writable by every device's Remotely Save, so a file is served only while its bytes still match.
 */
export class ObsidianPluginService {
  private readonly store: Store;
  private readonly vault: VaultStore | null;
  private readonly fetch: FetchFn;
  private readonly githubToken: string | undefined;
  private readonly now: () => number;
  private readonly logger: Logger;
  private running: Promise<PluginMirrorResult> | null = null;

  constructor({ store, vault, fetch = globalThis.fetch, githubToken, now = Date.now, logger = console }: ObsidianPluginServiceOptions) {
    this.store = store;
    this.vault = vault;
    this.fetch = fetch;
    this.githubToken = githubToken;
    this.now = now;
    this.logger = logger;
  }

  private storage(): VaultStore {
    if (!this.vault) throw notConfigured();
    return this.vault;
  }

  /** Turns bucket failures into 502 vault_storage_error (like VaultService). */
  private async guard<T>(fn: () => Promise<T>): Promise<T> {
    try {
      return await fn();
    } catch (error) {
      if (!(error instanceof VaultStorageError)) throw error;
      this.logger.error(`[obsidian-plugin] ${error.message}`);
      throw new AppError(502, "vault_storage_error", error.message);
    }
  }

  private async release(version: string): Promise<PluginRelease> {
    const release = VERSION_PATTERN.test(version) ? await this.store.getPluginRelease(version) : null;
    if (!release) throw notFound("Release", version);
    return release;
  }

  /** The newest mirrored release; 404 when nothing is mirrored yet. */
  async latest(): Promise<PluginRelease> {
    this.storage();
    const release = newest(await this.store.listPluginReleases());
    if (!release) throw new AppError(404, "not_found", "No Obsidian plugin release has been mirrored yet");
    return release;
  }

  /**
   * One file of a release (`version` null = the newest), read from the bucket.
   * 502 integrity_error when the bucket copy is missing or no longer matches the recorded SHA-256 and size.
   */
  async file(version: string | null, name: string): Promise<PluginFile> {
    const vault = this.storage();
    if (!isPluginFile(name)) throw notFound("File", name);
    const release = version === null ? await this.latest() : await this.release(version);
    const expected = release.files[name];
    const stored = await this.guard(() => vault.read(pluginPath(release.version, name)));
    if (!stored) {
      this.logger.error(`[obsidian-plugin] ${release.version}/${name} is missing from the bucket`);
      throw integrityError(`${name} of ${release.version} is missing from storage`);
    }
    const sha256 = sha256Hex(stored.body);
    if (sha256 !== expected.sha256 || stored.body.length !== expected.size) {
      this.logger.error(`[obsidian-plugin] ${release.version}/${name} in the bucket does not match its recorded SHA-256; not serving it`);
      throw integrityError(`${name} of ${release.version} in storage does not match its recorded SHA-256`);
    }
    return { release, name, body: stored.body, sha256, contentType: PLUGIN_CONTENT_TYPES[name] };
  }

  /** Mirrors every published release not mirrored yet and repairs the newest one; concurrent calls share a run. */
  async refresh(): Promise<PluginMirrorResult> {
    const vault = this.storage();
    this.running ??= this.mirror(vault).finally(() => {
      this.running = null;
    });
    return this.running;
  }

  private async mirror(vault: VaultStore): Promise<PluginMirrorResult> {
    const releases = await this.listGitHub();
    const known = new Map((await this.store.listPluginReleases()).map((r) => [r.version, r]));
    const result: PluginMirrorResult = { latest: null, mirrored: [], repaired: [], failed: [] };
    const fail = (version: string, error: unknown) => {
      result.failed.push({ version, error: message(error) });
      this.logger.error(`[obsidian-plugin] mirroring ${version} failed: ${message(error)}`);
    };

    for (const release of releases) {
      if (known.has(release.version)) continue;
      try {
        known.set(release.version, await this.mirrorRelease(vault, release));
        result.mirrored.push(release.version);
        this.logger.info(`[obsidian-plugin] mirrored ${release.version}`);
      } catch (error) {
        fail(release.version, error);
      }
    }

    // The newest version is the one latest.json and /latest/ serve: put its files back if they were changed in the bucket.
    const latest = newest([...known.values()]);
    const source = latest && !result.mirrored.includes(latest.version) && releases.find((r) => r.version === latest.version);
    if (latest && source) {
      try {
        if (await this.repair(vault, source, latest)) {
          result.repaired.push(latest.version);
          this.logger.warn(`[obsidian-plugin] ${latest.version}: bucket files did not match their SHA-256; restored from GitHub`);
        }
      } catch (error) {
        fail(latest.version, error);
      }
    }
    result.latest = latest?.version ?? null;
    return result;
  }

  private async listGitHub(): Promise<GitHubPluginRelease[]> {
    const headers: Record<string, string> = {
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": USER_AGENT,
    };
    if (this.githubToken) headers.Authorization = `Bearer ${this.githubToken}`;
    let response: Response;
    try {
      response = await this.fetch(PLUGIN_RELEASES_URL, { headers, signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
    } catch (error) {
      throw githubUnavailable(`request failed: ${message(error)}`);
    }
    if (!response.ok) throw githubUnavailable(`HTTP ${response.status}`);
    let json: unknown;
    try {
      json = await response.json();
    } catch {
      throw githubUnavailable("the listing is not valid JSON");
    }
    return parseGitHubReleases(json);
  }

  /** Downloads a release file and checks it against GitHub's digest (when GitHub reports one). */
  private async download(release: GitHubPluginRelease, name: PluginFileName): Promise<Buffer> {
    const asset = release.assets[name];
    // Release assets are public: the token is only for the API (and fetch would drop it on the redirect anyway)
    const response = await this.fetch(asset.url, {
      headers: { Accept: "application/octet-stream", "User-Agent": USER_AGENT },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!response.ok) throw new Error(`downloading ${name} failed: HTTP ${response.status}`);
    if (Number(response.headers.get("content-length")) > MAX_ASSET_BYTES) throw new Error(`${name} is too large`);
    const body = Buffer.from(await response.arrayBuffer());
    if (body.length > MAX_ASSET_BYTES) throw new Error(`${name} is too large`);
    if (asset.sha256 && sha256Hex(body) !== asset.sha256) throw new Error(`${name} does not match GitHub's SHA-256 digest`);
    return body;
  }

  /** Not recorded in the vault change feed (GET /v1/vault/changes): no client syncs the .localocr/ dot folder. */
  private async put(vault: VaultStore, version: string, name: PluginFileName, body: Buffer): Promise<void> {
    await vault.write(pluginPath(version, name), body, { mtime: this.now(), contentType: PLUGIN_CONTENT_TYPES[name] });
  }

  /** Downloads and verifies both files, stores them in the bucket, then records the release (the commit point). */
  private async mirrorRelease(vault: VaultStore, release: GitHubPluginRelease): Promise<PluginRelease> {
    const main = await this.download(release, "main.js");
    const manifest = await this.download(release, "manifest.json");
    const { minAppVersion } = checkManifest(manifest, release.version);
    await this.put(vault, release.version, "main.js", main);
    await this.put(vault, release.version, "manifest.json", manifest);

    const mirroredAt = new Date(this.now()).toISOString();
    const published = Date.parse(release.publishedAt ?? "");
    const record: PluginRelease = {
      version: release.version,
      minAppVersion,
      notes: release.notes,
      publishedAt: Number.isFinite(published) ? new Date(published).toISOString() : mirroredAt,
      files: {
        "main.js": { sha256: sha256Hex(main), size: main.length },
        "manifest.json": { sha256: sha256Hex(manifest), size: manifest.length },
      },
      mirroredAt,
    };
    // Another instance may have recorded it first (same GitHub bytes): keep its record
    if (await this.store.insertPluginRelease(record)) return record;
    return (await this.store.getPluginRelease(release.version)) ?? record;
  }

  /** Re-downloads bucket files that are missing or no longer match the record. True when something was rewritten. */
  private async repair(vault: VaultStore, source: GitHubPluginRelease, record: PluginRelease): Promise<boolean> {
    let repaired = false;
    for (const name of PLUGIN_FILES) {
      const expected = record.files[name];
      const stored = await vault.read(pluginPath(record.version, name));
      if (stored && sha256Hex(stored.body) === expected.sha256) continue;
      const body = await this.download(source, name);
      if (sha256Hex(body) !== expected.sha256) throw new Error(`${name} on GitHub no longer matches the recorded SHA-256`);
      await this.put(vault, record.version, name, body);
      repaired = true;
    }
    return repaired;
  }
}

/**
 * Mirrors on startup (after `delayMs`) and then every `intervalMs`. Failures are logged and never thrown.
 * Returns a function that stops the timers.
 */
export function schedulePluginMirror(
  service: Pick<ObsidianPluginService, "refresh">,
  {
    delayMs = PLUGIN_MIRROR_DELAY_MS,
    intervalMs = PLUGIN_MIRROR_INTERVAL_MS,
    logger = console,
  }: { delayMs?: number; intervalMs?: number; logger?: Pick<Console, "error"> } = {},
): () => void {
  const run = () => {
    service.refresh().catch((error: unknown) => logger.error(`[obsidian-plugin] mirror failed: ${message(error)}`));
  };
  const first = setTimeout(run, delayMs);
  const every = setInterval(run, intervalMs);
  first.unref();
  every.unref();
  return () => {
    clearTimeout(first);
    clearInterval(every);
  };
}
