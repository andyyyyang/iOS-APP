import { createHash } from "node:crypto";
import { promisify } from "node:util";
import { gzip } from "node:zlib";
import { AppError, notFound } from "../errors.js";
import { LinkResolver } from "../vault/links.js";
import { PARSER_VERSION, parseNote, type ParsedNote, type ParsedNoteDetail } from "../vault/markdown.js";
import { extensionOf, vaultPath } from "../vault/paths.js";
import type { VaultEntry } from "../vault/types.js";
import type { VaultService } from "./vault.js";
import type { VaultChangeFeed } from "./vault-changes.js";

// GET /v1/vault/index: every note's links, tags, tasks and snippet, so the app's graph, backlinks, tags and tasks
// cover the whole vault and not only the notes it downloaded. Notes are re-read only when their etag changes.

export const VAULT_INDEX_VERSION = 1;
/** A built index is reused this long (unless a change went through this server in between). */
export const VAULT_INDEX_CACHE_MS = 5_000;
export const VAULT_INDEX_FETCH_CONCURRENCY = 8;

export interface VaultIndexNote extends ParsedNote {
  path: string;
  mtime: number;
  size: number;
  etag: string;
}

export interface VaultIndexFile {
  path: string;
  mtime: number;
  size: number;
}

export interface VaultIndexBody {
  version: typeof VAULT_INDEX_VERSION;
  notes: VaultIndexNote[];
  files: VaultIndexFile[];
}

export interface VaultLinks {
  path: string;
  /** Resolved targets of the file's wikilinks (unresolved links are left out). */
  outgoing: string[];
  /** Notes with a wikilink resolving to the file. */
  backlinks: string[];
}

/** One build of the index plus what link resolution needs. */
export interface VaultIndexSnapshot {
  /** Bare ETag value: sha1 of the sorted path+etag pairs and the parser version. */
  etag: string;
  body: VaultIndexBody;
  json: string;
  /** Every listed file (notes with their aliases): the link resolution universe. */
  resolver: LinkResolver;
  /** Parsed notes by path, with every link target (attachments included). */
  details: ReadonlyMap<string, ParsedNoteDetail>;
  /** The JSON body gzipped (computed once). */
  gzipped(): Promise<Buffer>;
}

const gzipAsync = promisify(gzip);

/** Dot folders and files (.obsidian, .trash) hold app state, not notes. */
export const isHiddenPath = (path: string) => path.split("/").some((segment) => segment.startsWith("."));

async function mapLimit<T, R>(items: readonly T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await fn(items[index]!);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

export class VaultIndexService {
  /** path → the etag it was parsed at; re-read only when the listing reports another etag. */
  private readonly parsed = new Map<string, { etag: string; detail: ParsedNoteDetail }>();
  private cached: { snapshot: VaultIndexSnapshot; builtAt: number; cursor: string } | null = null;
  private inflight: Promise<VaultIndexSnapshot> | null = null;

  constructor(
    private readonly vault: VaultService,
    /** Its cursor moving means a write went through this server: the cached build is stale. */
    private readonly changes: VaultChangeFeed | null = null,
    private readonly options: { now?: () => number; cacheMs?: number; concurrency?: number } = {},
  ) {}

  /** The current index; built at most every 5 s. `fresh` lists the vault again now (unchanged notes are not re-read). */
  async snapshot({ fresh = false }: { fresh?: boolean } = {}): Promise<VaultIndexSnapshot> {
    const now = this.options.now ?? Date.now;
    const cursor = this.changes?.cursor ?? "";
    const cached = this.cached;
    if (!fresh && cached && cached.cursor === cursor && now() - cached.builtAt < (this.options.cacheMs ?? VAULT_INDEX_CACHE_MS)) {
      return cached.snapshot;
    }
    if (!fresh && this.inflight) return this.inflight;
    const build = this.build().then((snapshot) => {
      this.cached = { snapshot, builtAt: now(), cursor };
      return snapshot;
    });
    if (!fresh) {
      this.inflight = build;
      const clear = () => {
        if (this.inflight === build) this.inflight = null;
      };
      build.then(clear, clear);
    }
    return build;
  }

  /** Drops the cached build (the per-note parse cache stays: etags decide what is re-read). */
  invalidate(): void {
    this.cached = null;
  }

  private async build(): Promise<VaultIndexSnapshot> {
    const { items } = await this.vault.list({ recursive: true });
    const visible = items.filter((entry) => !isHiddenPath(entry.path));
    const notes = visible.filter((entry) => extensionOf(entry.path) === "md");
    const files = visible.filter((entry) => extensionOf(entry.path) !== "md");

    const parsedNotes = await mapLimit(notes, this.options.concurrency ?? VAULT_INDEX_FETCH_CONCURRENCY, (entry) =>
      this.parse(entry),
    );
    const present = new Set(notes.map((entry) => entry.path));
    for (const path of this.parsed.keys()) if (!present.has(path)) this.parsed.delete(path);

    const details = new Map<string, ParsedNoteDetail>();
    const body: VaultIndexBody = { version: VAULT_INDEX_VERSION, notes: [], files: [] };
    const listed: VaultEntry[] = [];
    notes.forEach((entry, index) => {
      const detail = parsedNotes[index];
      if (!detail) return; // deleted since the listing
      details.set(entry.path, detail);
      listed.push(entry);
      body.notes.push({
        path: entry.path,
        mtime: entry.mtime,
        size: entry.size,
        etag: entry.etag,
        title: detail.title,
        aliases: detail.aliases,
        tags: detail.tags,
        links: detail.links,
        firstEmbed: detail.firstEmbed,
        tasks: detail.tasks,
        snippet: detail.snippet,
        notebook: detail.notebook,
        properties: detail.properties,
        fields: detail.fields,
      });
    });
    for (const entry of files) {
      listed.push(entry);
      body.files.push({ path: entry.path, mtime: entry.mtime, size: entry.size });
    }

    const hash = createHash("sha1").update(`index:${VAULT_INDEX_VERSION};parser:${PARSER_VERSION}\n`);
    for (const entry of [...listed].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))) {
      hash.update(`${entry.path}\u0000${entry.etag}\n`);
    }
    const json = JSON.stringify(body);
    let gzipped: Promise<Buffer> | null = null;
    return {
      etag: hash.digest("hex"),
      body,
      json,
      resolver: new LinkResolver([
        ...body.notes.map((note) => ({ path: note.path, aliases: note.aliases })),
        ...body.files.map((file) => ({ path: file.path })),
      ]),
      details,
      gzipped: () => (gzipped ??= gzipAsync(Buffer.from(json, "utf8"))),
    };
  }

  /** The note's parsed fields: cached for an unchanged etag, otherwise read; null when it disappeared. */
  private async parse(entry: VaultEntry): Promise<ParsedNoteDetail | null> {
    const cached = this.parsed.get(entry.path);
    if (cached && cached.etag === entry.etag) return cached.detail;
    let text = "";
    try {
      const file = await this.vault.read(entry.path);
      text = file.body.toString("utf8");
    } catch (error) {
      if (error instanceof AppError && error.status === 404) return null;
      // a stored key that is not a valid vault path (e.g. "a//b.md"): listed, but its content cannot be read
      if (!(error instanceof AppError && error.status === 400)) throw error;
    }
    const detail = parseNote(entry.path, text);
    this.parsed.set(entry.path, { etag: entry.etag, detail });
    return detail;
  }

  /**
   * Outgoing links and backlinks of a file, Obsidian-style (path, then file name with the shortest path winning, then
   * aliases; case-insensitive). `rawPath` may also be a link target such as "Note". 404 when nothing matches.
   */
  async links(rawPath: unknown): Promise<VaultLinks> {
    const requested = vaultPath(rawPath);
    const snapshot = await this.snapshot();
    const path = snapshot.details.has(requested) ? requested : snapshot.resolver.resolve(requested);
    if (!path) throw notFound("File", requested);
    return linksOf(snapshot, path);
  }
}

/** Outgoing links and backlinks of `path` within one index build. */
export function linksOf(snapshot: VaultIndexSnapshot, path: string): VaultLinks {
  const resolve = (target: string) => snapshot.resolver.resolve(target);
  const outgoing: string[] = [];
  for (const target of snapshot.details.get(path)?.allLinks ?? []) {
    const resolved = resolve(target);
    if (resolved && resolved !== path && !outgoing.includes(resolved)) outgoing.push(resolved);
  }
  const backlinks: string[] = [];
  for (const [source, detail] of snapshot.details) {
    if (source !== path && detail.allLinks.some((target) => resolve(target) === path)) backlinks.push(source);
  }
  return { path, outgoing, backlinks };
}

