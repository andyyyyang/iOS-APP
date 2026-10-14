import type { IncomingMessage, Server } from "node:http";
import type { Duplex } from "node:stream";
import type { Express } from "express";
import { WebSocket, WebSocketServer, type RawData } from "ws";
import type { Services } from "../services/index.js";
import type { VaultChange } from "../services/vault-changes.js";
import { apiKeyChecker } from "./auth.js";

// WebSocket GET /v1/vault/stream: the vault change feed pushed the moment it changes, instead of long-polling
// GET /v1/vault/changes. Browsers cannot set headers on a WebSocket, so the API key comes in the first message.
//
//   client → {"type":"auth","token":"<API key>","client":"<client id>","since":"<cursor>"?}   (within 10 s)
//   server → {"type":"ready","cursor","reset"}, then {"type":"changes",…} when `since` missed changes by others
//   server → {"type":"changes","cursor","reset":false,"changes":[VaultChange…]} for changes made by other clients
//   client → {"type":"report","paths":[…]?} → {"type":"ack","cursor"}   (like POST /v1/vault/changes)
//   client → {"type":"ping"} → {"type":"pong"}
//   bad key: {"type":"error","code":"unauthorized"} + close 4401 (no auth within 10 s: close 4401 only)
//   no vault: {"type":"error","code":"vault_not_configured"} + close 4503
// Same cursors and "own changes are left out" rule as GET /v1/vault/changes. The server pings every 30 s and
// terminates a socket that did not answer the previous ping.

export const VAULT_STREAM_PATH = "/v1/vault/stream";
/** The auth message must arrive within this long. */
export const VAULT_STREAM_AUTH_TIMEOUT_MS = 10_000;
/** WebSocket ping interval; a socket that has not answered the previous ping by the next one is terminated. */
export const VAULT_STREAM_HEARTBEAT_MS = 30_000;
/** Changes recorded within this long of each other are pushed in one message. */
export const VAULT_STREAM_BATCH_MS = 50;
/** Largest message a client may send (a report of 100 paths of up to 1024 bytes fits easily). */
export const VAULT_STREAM_MAX_PAYLOAD = 256 * 1024;
export const VAULT_STREAM_CLOSE_UNAUTHORIZED = 4401;
export const VAULT_STREAM_CLOSE_NOT_CONFIGURED = 4503;
const CLOSE_GOING_AWAY = 1001;
/** After close(): sockets that have not finished the close handshake by then are cut. */
const SHUTDOWN_GRACE_MS = 2_000;

export type VaultStreamServerMessage =
  | { type: "ready"; cursor: string; reset: boolean }
  | { type: "changes"; cursor: string; reset: false; changes: VaultChange[] }
  | { type: "ack"; cursor: string }
  | { type: "pong" }
  | { type: "error"; code: "unauthorized" | "vault_not_configured" };

/** What the stream needs from the app: the services behind it and its API keys. */
export interface VaultStreamDeps {
  services: Pick<Services, "vault" | "vaultChanges">;
  /** Same keys (and same "empty disables auth" rule) as the app's REST auth. */
  apiKeys: readonly string[];
}

const appDeps = new WeakMap<Express, VaultStreamDeps>();

/** createApp registers its services and API keys here, so attachVaultStream(server, app) can find them. */
export function registerVaultStream(app: Express, deps: VaultStreamDeps): void {
  appDeps.set(app, deps);
}

function depsOf(source: Express | VaultStreamDeps): VaultStreamDeps {
  if (typeof source !== "function") return source;
  const deps = appDeps.get(source);
  if (!deps) throw new Error("attachVaultStream: the app was not built by createApp");
  return deps;
}

export interface VaultStreamOptions {
  authTimeoutMs?: number;
  heartbeatMs?: number;
  batchMs?: number;
}

export interface VaultStream {
  /** Open, authenticated sockets (for tests and diagnostics). */
  readonly clients: number;
  /** Shutdown: refuses new streams, pushes what is pending and closes every socket (1001). */
  close(): void;
}

interface Peer {
  socket: WebSocket;
  /** The auth message's client id: changes recorded under it are not pushed to this socket. */
  client: string | null;
  /** Every change up to this seq has been covered (by ready or an earlier push). */
  sentSeq: number;
}

type ClientMessage = Record<string, unknown> & { type: string };

function parseMessage(data: RawData): ClientMessage | null {
  const text = Buffer.isBuffer(data)
    ? data.toString("utf8")
    : Array.isArray(data)
      ? Buffer.concat(data).toString("utf8")
      : Buffer.from(data).toString("utf8");
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return null;
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const message = value as Record<string, unknown>;
  return typeof message.type === "string" ? (message as ClientMessage) : null;
}

function send(socket: WebSocket, message: VaultStreamServerMessage): void {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}

/**
 * Serves GET /v1/vault/stream on `server` (the HTTP server listening with the app: index.ts after app.listen, tests
 * with app.listen(0)) through its "upgrade" event; upgrade requests for any other path are dropped. `source` is the
 * app built by createApp, or its services and API keys directly.
 */
export function attachVaultStream(
  server: Server,
  source: Express | VaultStreamDeps,
  {
    authTimeoutMs = VAULT_STREAM_AUTH_TIMEOUT_MS,
    heartbeatMs = VAULT_STREAM_HEARTBEAT_MS,
    batchMs = VAULT_STREAM_BATCH_MS,
  }: VaultStreamOptions = {},
): VaultStream {
  const {
    services: { vault, vaultChanges },
    apiKeys,
  } = depsOf(source);
  const checkKey = apiKeyChecker(apiKeys);
  const wss = new WebSocketServer({ noServer: true, maxPayload: VAULT_STREAM_MAX_PAYLOAD });
  /** Every open socket, and whether it has answered the latest heartbeat ping. */
  const alive = new Map<WebSocket, boolean>();
  const peers = new Set<Peer>();
  let pending: VaultChange[] = [];
  let flushTimer: NodeJS.Timeout | null = null;
  let closed = false;

  function flush(): void {
    flushTimer = null;
    const batch = pending;
    pending = [];
    const last = batch[batch.length - 1];
    if (!last) return;
    const cursor = vaultChanges.cursor;
    for (const peer of peers) {
      const changes = batch.filter(
        (change) => change.seq > peer.sentSeq && (peer.client === null || change.client !== peer.client),
      );
      peer.sentSeq = Math.max(peer.sentSeq, last.seq);
      // Nothing left after leaving out its own changes: nothing to send (its next `since` still works)
      if (changes.length) send(peer.socket, { type: "changes", cursor, reset: false, changes });
    }
  }

  const unsubscribe = vaultChanges.subscribe((changes) => {
    if (peers.size === 0) return;
    pending.push(...changes);
    flushTimer ??= setTimeout(flush, batchMs);
  });

  /** Checks the first message; on success sends ready (plus what `since` missed) and returns the peer. */
  function authenticate(socket: WebSocket, message: ClientMessage | null): Peer | null {
    const token = message?.type === "auth" && typeof message.token === "string" && message.token ? [message.token] : [];
    if (!message || message.type !== "auth" || !checkKey(token).ok) {
      send(socket, { type: "error", code: "unauthorized" });
      socket.close(VAULT_STREAM_CLOSE_UNAUTHORIZED, "Missing or invalid API key");
      return null;
    }
    if (!vault.status().configured) {
      send(socket, { type: "error", code: "vault_not_configured" });
      socket.close(VAULT_STREAM_CLOSE_NOT_CONFIGURED, "Vault storage is not configured");
      return null;
    }
    const client = vault.streamClientId(message.client);
    // Synchronous, like everything up to peers.add: no change can slip between this answer and the first push
    const missed = vaultChanges.changesSince(message.since ?? undefined, client);
    const peer: Peer = { socket, client, sentSeq: vaultChanges.latestSeq };
    peers.add(peer);
    send(socket, { type: "ready", cursor: missed.cursor, reset: missed.reset });
    if (missed.changes.length) {
      send(socket, { type: "changes", cursor: missed.cursor, reset: false, changes: missed.changes });
    }
    return peer;
  }

  function handle(peer: Peer, message: ClientMessage | null): void {
    switch (message?.type) {
      case "ping":
        send(peer.socket, { type: "pong" });
        break;
      case "report": {
        const { cursor } = vault.reportExternalLenient(message.paths, peer.client);
        send(peer.socket, { type: "ack", cursor });
        break;
      }
      default:
        break; // unknown or not JSON: ignored
    }
  }

  function onConnection(socket: WebSocket): void {
    alive.set(socket, true);
    let peer: Peer | null = null;
    const authTimer = setTimeout(
      () => socket.close(VAULT_STREAM_CLOSE_UNAUTHORIZED, "Authentication timed out"),
      authTimeoutMs,
    );
    socket.on("pong", () => {
      if (alive.has(socket)) alive.set(socket, true);
    });
    socket.on("message", (data) => {
      if (socket.readyState !== WebSocket.OPEN) return;
      try {
        const message = parseMessage(data);
        if (peer) {
          handle(peer, message);
        } else {
          clearTimeout(authTimer);
          peer = authenticate(socket, message);
        }
      } catch (error) {
        console.error("[vault-stream] message failed:", error instanceof Error ? error.message : error);
      }
    });
    // ws closes the socket itself after a protocol error (e.g. 1009 for a message over maxPayload)
    socket.on("error", () => {});
    socket.on("close", () => {
      clearTimeout(authTimer);
      alive.delete(socket);
      if (peer) peers.delete(peer);
    });
  }

  server.on("upgrade", (req: IncomingMessage, socket: Duplex, head: Buffer) => {
    const path = (req.url ?? "").split("?", 1)[0];
    if (closed || path !== VAULT_STREAM_PATH) {
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, onConnection);
  });

  const heartbeat = setInterval(() => {
    for (const [socket, answered] of alive) {
      if (!answered) {
        socket.terminate();
        continue;
      }
      alive.set(socket, false);
      socket.ping();
    }
  }, heartbeatMs);
  heartbeat.unref();

  return {
    get clients() {
      return peers.size;
    },
    close() {
      if (closed) return;
      closed = true;
      unsubscribe();
      clearInterval(heartbeat);
      if (flushTimer) {
        clearTimeout(flushTimer);
        flush();
      }
      for (const socket of alive.keys()) socket.close(CLOSE_GOING_AWAY, "Server shutting down");
      setTimeout(() => {
        for (const socket of alive.keys()) socket.terminate();
      }, SHUTDOWN_GRACE_MS).unref();
      wss.close();
    },
  };
}
