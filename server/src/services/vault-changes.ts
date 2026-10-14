import { randomBytes } from "node:crypto";

// Near-real-time vault sync: every vault write and delete made through this server (REST, MCP) is recorded here.
// Clients hear about them at once over the WebSocket GET /v1/vault/stream (subscribe()), or by long-polling
// GET /v1/vault/changes (poll()). Obsidian devices, which sync the bucket directly with Remotely Save, report their
// uploads with POST /v1/vault/changes or a stream "report" message ("external" entries).
// The log lives in memory (one Railway instance): a restart starts a new epoch and every client's cursor resets.

export type VaultChangeOp = "write" | "delete" | "external";

export interface VaultChange {
  /** Increases by one per change within an epoch. */
  seq: number;
  /** Vault-relative path; null for an "external" report that names no files. */
  path: string | null;
  op: VaultChangeOp;
  /** X-LocalOCR-Client of the request that made the change, "mcp" for MCP tools, null when unknown. */
  client: string | null;
  /** ISO 8601. */
  at: string;
}

export interface VaultChangesResponse {
  /** "<epoch>:<latest seq>": pass it back as `since`. Always the latest seq, so the caller skips its own changes too. */
  cursor: string;
  /** The changes since `since` cannot be listed (unknown cursor, gap, or too many): reload everything. */
  reset: boolean;
  changes: VaultChange[];
}

export type VaultChangeInput = Pick<VaultChange, "path" | "op" | "client">;

/** Changes kept in memory; a cursor older than the oldest one answers reset: true. */
export const VAULT_CHANGES_CAPACITY = 1000;
/** Most changes in one response; more answer reset: true. */
export const VAULT_CHANGES_MAX_RESPONSE = 200;
/** The `client` recorded for MCP tool writes. */
export const MCP_CLIENT_ID = "mcp";

/**
 * Called synchronously inside record() with the changes just recorded (copies, oldest first) and the new cursor.
 * Must not throw (a throw is logged and ignored).
 */
export type VaultChangeListener = (changes: VaultChange[], cursor: string) => void;

interface Waiter {
  since: number;
  client: string | null;
  finish: (response: VaultChangesResponse) => void;
}

export interface PollOptions {
  /** The caller's cursor; undefined or "" = none yet (answers the current cursor right away). */
  since?: unknown;
  /** The caller's X-LocalOCR-Client: its own changes are left out. null = nothing is left out. */
  client: string | null;
  /** How long to hold the request when there is nothing new (0 = answer right away). */
  waitMs: number;
  /** Aborting (the client disconnected) drops the waiter. */
  signal?: AbortSignal;
}

/** In-memory ring of the latest vault changes plus the long-polls and stream subscribers waiting for the next one. */
export class VaultChangeFeed {
  /** Random per process: cursors from before a restart are recognized as stale. */
  readonly epoch: string;
  private latest = 0;
  /** Consecutive seqs, oldest first; at most `capacity`. */
  private readonly entries: VaultChange[] = [];
  private readonly waiters = new Set<Waiter>();
  private readonly listeners = new Set<VaultChangeListener>();
  private closed = false;
  private readonly capacity: number;
  private readonly maxResponse: number;
  private readonly now: () => number;

  constructor({
    capacity = VAULT_CHANGES_CAPACITY,
    maxResponse = VAULT_CHANGES_MAX_RESPONSE,
    epoch = randomBytes(6).toString("hex"),
    now = Date.now,
  }: { capacity?: number; maxResponse?: number; epoch?: string; now?: () => number } = {}) {
    if (!(capacity >= 1)) throw new Error("capacity must be at least 1");
    if (epoch.includes(":")) throw new Error('epoch must not contain ":"');
    this.capacity = capacity;
    this.maxResponse = maxResponse;
    this.epoch = epoch;
    this.now = now;
  }

  get cursor(): string {
    return `${this.epoch}:${this.latest}`;
  }

  /** The seq of the latest change (0 before the first one). */
  get latestSeq(): number {
    return this.latest;
  }

  /** Long-polls currently held open (for tests and diagnostics). */
  get waiting(): number {
    return this.waiters.size;
  }

  /** Current subscribe() listeners (for tests and diagnostics). */
  get subscribers(): number {
    return this.listeners.size;
  }

  /**
   * Appends the changes (one seq each), wakes the long-polls they concern, tells every subscriber and returns the
   * new cursor.
   */
  record(changes: readonly VaultChangeInput[]): string {
    if (changes.length === 0) return this.cursor;
    const at = new Date(this.now()).toISOString();
    const added = changes.map(({ path, op, client }): VaultChange => {
      this.latest += 1;
      return { seq: this.latest, path, op, client, at };
    });
    this.entries.push(...added);
    if (this.entries.length > this.capacity) this.entries.splice(0, this.entries.length - this.capacity);
    for (const waiter of [...this.waiters]) {
      const found = this.collect(waiter.since, waiter.client);
      if (found) waiter.finish(found);
    }
    const cursor = this.cursor;
    for (const listener of [...this.listeners]) {
      try {
        listener(added.map((change) => ({ ...change })), cursor);
      } catch (error) {
        // The change is already recorded (and the write behind it done): a failing subscriber must not fail it
        console.error("[vault-changes] subscriber failed:", error instanceof Error ? error.message : error);
      }
    }
    return cursor;
  }

  /** Calls `listener` for every change recorded from now on, until the returned function is called. */
  subscribe(listener: VaultChangeListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  /**
   * What a poll with waitMs 0 answers, synchronously: the changes after `since` made by anyone but `client`
   * (null = nothing is left out), the current cursor with no changes when `since` is missing, or reset: true when
   * `since` is unusable or too far behind.
   */
  changesSince(since: unknown, client: string | null): VaultChangesResponse {
    if (since === undefined || since === "") return this.answer(false, []);
    const seq = this.parseCursor(since);
    if (seq === null) return this.answer(true, []);
    return this.collect(seq, client) ?? this.answer(false, []);
  }

  /**
   * Changes after `since` made by anyone but `client`. Answers right away when there are some, when `since` is
   * missing (current cursor, no changes) or unusable (reset: true); otherwise holds until such a change is recorded
   * or `waitMs` passes (then with no changes).
   */
  poll({ since, client, waitMs, signal }: PollOptions): Promise<VaultChangesResponse> {
    if (since === undefined || since === "") return Promise.resolve(this.answer(false, []));
    const seq = this.parseCursor(since);
    if (seq === null) return Promise.resolve(this.answer(true, []));
    const found = this.collect(seq, client);
    if (found || !(waitMs > 0) || this.closed || signal?.aborted) return Promise.resolve(found ?? this.answer(false, []));

    return new Promise((resolve) => {
      const waiter: Waiter = {
        since: seq,
        client,
        finish: (response) => {
          clearTimeout(timer);
          signal?.removeEventListener("abort", onAbort);
          this.waiters.delete(waiter);
          resolve(response);
        },
      };
      const onAbort = () => waiter.finish(this.answer(false, []));
      const timer = setTimeout(onAbort, waitMs);
      signal?.addEventListener("abort", onAbort, { once: true });
      this.waiters.add(waiter);
    });
  }

  /** Answers every held long-poll now (server shutdown); later polls never wait. */
  close(): void {
    this.closed = true;
    for (const waiter of [...this.waiters]) waiter.finish(this.answer(false, []));
  }

  private answer(reset: boolean, changes: VaultChange[]): VaultChangesResponse {
    return { cursor: this.cursor, reset, changes: changes.map((change) => ({ ...change })) };
  }

  /** The seq in "<epoch>:<seq>" when it belongs to this epoch and is not ahead of the log; else null. */
  private parseCursor(cursor: unknown): number | null {
    if (typeof cursor !== "string") return null;
    const colon = cursor.lastIndexOf(":");
    if (colon < 0 || cursor.slice(0, colon) !== this.epoch) return null;
    const digits = cursor.slice(colon + 1);
    if (!/^\d{1,15}$/.test(digits)) return null;
    const seq = Number(digits);
    return seq <= this.latest ? seq : null;
  }

  /** What a poll from `since` gets now; null when nothing concerns `client` yet. */
  private collect(since: number, client: string | null): VaultChangesResponse | null {
    const oldest = this.entries[0]?.seq ?? this.latest + 1;
    if (since < oldest - 1) return this.answer(true, []); // some changes after `since` were already dropped
    const changes: VaultChange[] = [];
    for (let index = since - oldest + 1; index < this.entries.length; index += 1) {
      const entry = this.entries[index]!;
      if (client === null || entry.client !== client) changes.push(entry);
    }
    if (changes.length === 0) return null;
    return changes.length > this.maxResponse ? this.answer(true, []) : this.answer(false, changes);
  }
}
