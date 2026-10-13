import type { VaultConfig } from "../config.js";
import { AppError, notFound } from "../errors.js";
import { remotelySaveQuerySchema, vaultListQuerySchema, vaultSearchQuerySchema } from "../schemas.js";
import type { WriteResult } from "../store/types.js";
import { contentTypeFor, extensionOf, normalizeEtag, vaultFolder, vaultPath } from "../vault/paths.js";
import { remotelySaveSettings, remotelySaveUri, type RemotelySaveSettings } from "../vault/remotely-save.js";
import { VaultStorageError, type VaultEntry, type VaultFile, type VaultStore } from "../vault/types.js";
import { parse } from "./parse.js";

export const SEARCH_EXTENSIONS: ReadonlySet<string> = new Set(["md", "txt", "json", "canvas"]);
export const SEARCH_MAX_FILES = 3000;
export const SEARCH_MAX_FILE_BYTES = 1024 * 1024;
const SEARCH_CONCURRENCY = 8;
const SNIPPET_LENGTH = 120;
const SNIPPET_LEAD = 40;

export interface VaultStatus {
  configured: boolean;
  prefix: string;
}

export interface VaultList {
  items: VaultEntry[];
  /** Only for non-recursive listings. */
  folders?: string[];
}

export interface VaultSearchHit {
  path: string;
  mtime: number;
  snippet: string;
}

export interface RemotelySaveSetup {
  settings: RemotelySaveSettings;
  /** obsidian://remotely-save?func=settings&… for `vault`; null when no vault name was given. */
  uri: string | null;
}

export interface VaultWriteInput {
  /** Etag (or list, or "*") the current file must match. */
  ifMatch?: string;
  /** "*" = only create; fails when the file exists. */
  ifNoneMatch?: string;
  /** Milliseconds; defaults to now. */
  mtime?: number;
}

const notConfigured = () =>
  new AppError(503, "vault_not_configured", "Vault storage is not configured (set VAULT_S3_* variables)");

const byPath = (a: { path: string }, b: { path: string }) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0);

function etagMatches(header: string, current: VaultEntry | null): boolean {
  if (!current) return false;
  if (header.trim() === "*") return true;
  return header.split(",").some((tag) => normalizeEtag(tag) === current.etag);
}

const preconditionFailed = (message: string, current: VaultEntry | null) =>
  new AppError(412, "precondition_failed", message, { currentEtag: current?.etag ?? null });

const changed = (current: VaultEntry | null) =>
  preconditionFailed(current ? "File has changed since it was read (etag mismatch)" : "File does not exist", current);

/** Vault files written on macOS may be named in NFD; fall back to that spelling when the NFC one is missing. */
async function lookup<T>(path: string, find: (path: string) => Promise<T | null>): Promise<T | null> {
  const found = await find(path);
  const nfd = path.normalize("NFD");
  return found ?? (nfd !== path ? find(nfd) : null);
}

const basename = (path: string) => path.slice(path.lastIndexOf("/") + 1);

/** Dot folders and files (.obsidian, .trash) hold app state, not notes. */
const isHidden = (path: string) => path.split("/").some((segment) => segment.startsWith("."));

const escapeRegExp = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** ~120 characters around a match, whitespace collapsed, never splitting a surrogate pair. */
function snippetAround(text: string, index: number, length: number): string {
  let start = Math.max(0, index - SNIPPET_LEAD);
  let end = Math.min(text.length, Math.max(start + SNIPPET_LENGTH, index + length));
  const isLow = (i: number) => i < text.length && (text.charCodeAt(i) & 0xfc00) === 0xdc00;
  const isHigh = (i: number) => i >= 0 && (text.charCodeAt(i) & 0xfc00) === 0xd800;
  if (isLow(start)) start += 1;
  if (isHigh(end - 1)) end -= 1;
  const body = text.slice(start, end).replace(/\s+/g, " ").trim();
  return `${start > 0 ? "…" : ""}${body}${end < text.length ? "…" : ""}`;
}

/**
 * The user's Obsidian vault as plain files in an S3-compatible bucket (synced by Remotely Save).
 * Writes use optimistic concurrency: stat, compare the etag, then put (a tiny race window remains).
 */
export class VaultService {
  constructor(
    private readonly store: VaultStore | null,
    /** The bucket credentials, only for handing them to Remotely Save; null when VAULT_S3_* is not set. */
    private readonly config: VaultConfig | null = null,
  ) {}

  status(): VaultStatus {
    return { configured: this.store !== null, prefix: this.store?.prefix ?? "" };
  }

  private storage(): VaultStore {
    if (!this.store) throw notConfigured();
    return this.store;
  }

  /**
   * Remotely Save settings (S3 bucket keys included) for setting up another device in one step,
   * plus its import URI when `vault` names the Obsidian vault. Never log the result.
   */
  remotelySave(input: { vault?: unknown } = {}): RemotelySaveSetup {
    if (!this.config) throw notConfigured();
    const { vault } = parse(remotelySaveQuerySchema, input);
    const settings = remotelySaveSettings(this.config);
    return { settings, uri: vault === undefined ? null : remotelySaveUri(settings, vault) };
  }

  /** Turns backend failures into 502 vault_storage_error. */
  private async guard<T>(fn: () => Promise<T>): Promise<T> {
    try {
      return await fn();
    } catch (error) {
      if (!(error instanceof VaultStorageError)) throw error;
      console.error(`[vault] ${error.message}`);
      throw new AppError(502, "vault_storage_error", error.message);
    }
  }

  /** Files sorted by path; non-recursive listings also return child folders ("Notes/Daily/"). */
  async list(input: { prefix?: unknown; recursive?: unknown } = {}): Promise<VaultList> {
    const store = this.storage();
    const folder = vaultFolder(input.prefix);
    const { recursive } = parse(vaultListQuerySchema, { recursive: input.recursive });
    const listing = await this.guard(() => store.list(folder, { recursive }));
    const items = listing.items.sort(byPath);
    return recursive ? { items } : { items, folders: listing.folders.sort() };
  }

  async read(rawPath: unknown): Promise<VaultFile> {
    const store = this.storage();
    const path = vaultPath(rawPath);
    const file = await this.guard(() => lookup(path, (candidate) => store.read(candidate)));
    if (!file) throw notFound("File", path);
    return file;
  }

  /** Create-or-replace. `created` tells 201 from 200. Fails with 412 precondition_failed (+ currentEtag). */
  async write(rawPath: unknown, body: Buffer, { ifMatch, ifNoneMatch, mtime }: VaultWriteInput = {}): Promise<WriteResult<VaultEntry>> {
    const store = this.storage();
    const requested = vaultPath(rawPath);
    return this.guard(async () => {
      const current = await lookup(requested, (candidate) => store.stat(candidate));
      if (ifMatch !== undefined && !etagMatches(ifMatch, current)) throw changed(current);
      if (ifNoneMatch !== undefined && etagMatches(ifNoneMatch, current)) {
        throw preconditionFailed("File already exists", current);
      }
      const path = current?.path ?? requested;
      const value = await store.write(path, body, { mtime: mtime ?? Date.now(), contentType: contentTypeFor(path) });
      return { value, created: current === null };
    });
  }

  /** 404 when missing; 412 when `ifMatch` no longer matches. */
  async delete(rawPath: unknown, { ifMatch }: { ifMatch?: string } = {}): Promise<void> {
    const store = this.storage();
    const requested = vaultPath(rawPath);
    await this.guard(async () => {
      const current = await lookup(requested, (candidate) => store.stat(candidate));
      if (!current) throw notFound("File", requested);
      if (ifMatch !== undefined && !etagMatches(ifMatch, current)) throw changed(current);
      await store.delete(current.path);
    });
  }

  /**
   * Case-insensitive search over the names and contents of .md/.txt/.json/.canvas files (dot folders skipped),
   * newest first. Scans at most SEARCH_MAX_FILES files; content of files over 1 MB is not read.
   */
  async search(rawQuery: unknown, options: { prefix?: unknown; limit?: unknown } = {}): Promise<{ items: VaultSearchHit[] }> {
    const store = this.storage();
    const { q, limit } = parse(vaultSearchQuerySchema, { q: rawQuery, limit: options.limit });
    const folder = vaultFolder(options.prefix);
    const pattern = new RegExp(escapeRegExp(q), "iu");

    return this.guard(async () => {
      const { items } = await store.list(folder, { recursive: true });
      const candidates = items
        .filter((entry) => SEARCH_EXTENSIONS.has(extensionOf(entry.path)) && !isHidden(entry.path.slice(folder.length)))
        .sort((a, b) => b.mtime - a.mtime || byPath(a, b))
        .slice(0, SEARCH_MAX_FILES);

      // Newest first, in batches: once the limit is reached, no older file can outrank the hits.
      const hits: VaultSearchHit[] = [];
      for (let start = 0; start < candidates.length && hits.length < limit; start += SEARCH_CONCURRENCY) {
        const batch = candidates.slice(start, start + SEARCH_CONCURRENCY);
        for (const hit of await Promise.all(batch.map((entry) => this.match(store, entry, pattern)))) {
          if (hit) hits.push(hit);
        }
      }
      return { items: hits.slice(0, limit) };
    });
  }

  private async match(store: VaultStore, entry: VaultEntry, pattern: RegExp): Promise<VaultSearchHit | null> {
    const { path, mtime } = entry;
    const nameMatch = pattern.test(basename(path));
    if (entry.size > SEARCH_MAX_FILE_BYTES) return nameMatch ? { path, mtime, snippet: "" } : null;

    const file = await store.read(path);
    if (!file) return null; // deleted since the listing
    const text = file.body.toString("utf8").replace(/^﻿/, "");
    const found = pattern.exec(text);
    if (found) return { path, mtime, snippet: snippetAround(text, found.index, found[0].length) };
    return nameMatch ? { path, mtime, snippet: snippetAround(text, 0, 0) } : null;
  }
}
