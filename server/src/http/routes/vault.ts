import express, { Router, type Request } from "express";
import { vaultMtimeSchema } from "../../schemas.js";
import type { Services } from "../../services/index.js";
import { parse } from "../../services/parse.js";
import { VAULT_CLIENT_HEADER } from "../../services/vault.js";
import { contentTypeFor } from "../../vault/paths.js";

/** Response headers clients must be able to read cross-origin. */
export const VAULT_EXPOSED_HEADERS = ["ETag", "Last-Modified", "X-Vault-Mtime"];

// Raw bytes of any Content-Type: .json/.canvas uploads must stay byte-exact, not be parsed.
const rawBody = express.raw({ type: () => true, limit: "25mb" });

// POST /changes is the only JSON body here (at most 100 paths of at most 1024 bytes each).
const jsonBody = express.json({ limit: "256kb" });

const header = (req: Request, name: string) => req.get(name) || undefined;

/**
 * /v1/vault: the Obsidian vault's plain files (shared with Remotely Save through the bucket).
 * Mounted before the global JSON parser so PUT /file always receives raw bytes.
 */
export function vaultRouter({ vault }: Services): Router {
  const router = Router();
  /** X-LocalOCR-Client: recorded with the change and left out of that client's own change feed. */
  const client = (req: Request) => vault.clientId(header(req, VAULT_CLIENT_HEADER));

  router.get("/status", (_req, res) => {
    res.json(vault.status());
  });

  // Bucket keys for setting up Remotely Save on another device: never cache or log
  router.get("/remotely-save", (req, res) => {
    const setup = vault.remotelySave({ vault: req.query.vault });
    res.set("Cache-Control", "no-store").json(setup);
  });

  router.get("/files", async (req, res) => {
    res.json(await vault.list({ prefix: req.query.prefix, recursive: req.query.recursive }));
  });

  router.get("/file", async (req, res) => {
    const file = await vault.read(req.query.path);
    // setHeader keeps Content-Type exactly as given (res.set would append a charset to application/json)
    res.setHeader("Content-Type", contentTypeFor(file.path));
    res.set({
      ETag: `"${file.etag}"`,
      "Last-Modified": new Date(file.mtime).toUTCString(),
      "X-Vault-Mtime": String(file.mtime),
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    });
    res.send(file.body);
  });

  router.put("/file", rawBody, async (req, res) => {
    const mtime = parse(vaultMtimeSchema, header(req, "x-vault-mtime"), "X-Vault-Mtime: ");
    const body = Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0);
    const { value, created } = await vault.write(req.query.path, body, {
      ifMatch: header(req, "if-match"),
      ifNoneMatch: header(req, "if-none-match"),
      mtime,
      client: client(req),
    });
    res
      .status(created ? 201 : 200)
      .set("ETag", `"${value.etag}"`)
      .json({ path: value.path, size: value.size, mtime: value.mtime, etag: value.etag });
  });

  router.delete("/file", async (req, res) => {
    await vault.delete(req.query.path, { ifMatch: header(req, "if-match"), client: client(req) });
    res.status(204).end();
  });

  // Long poll (wait ≤ 25 s). There is no request timeout or compression middleware in this app, and the answer is a
  // single small JSON body, so nothing buffers or cuts it off; Node's default server.timeout (0) keeps the socket open.
  router.get("/changes", async (req, res) => {
    const requester = client(req);
    // res "close" also fires when the client disconnects early (req "close" may fire as soon as the request is read)
    const disconnected = new AbortController();
    res.on("close", () => disconnected.abort());
    const result = await vault.changes(
      { since: req.query.since, wait: req.query.wait },
      { client: requester, signal: disconnected.signal },
    );
    if (disconnected.signal.aborted) return; // nobody is listening any more
    res.set({ "Cache-Control": "no-store", "X-Accel-Buffering": "no" }).json(result);
  });

  router.post("/changes", jsonBody, (req, res) => {
    res.status(202).json(vault.reportExternal(req.body, client(req)));
  });

  router.get("/search", async (req, res) => {
    res.json(await vault.search(req.query.q, { prefix: req.query.prefix, limit: req.query.limit }));
  });

  return router;
}
