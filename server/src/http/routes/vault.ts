import express, { Router, type Request } from "express";
import { vaultMtimeSchema } from "../../schemas.js";
import type { Services } from "../../services/index.js";
import { parse } from "../../services/parse.js";
import { contentTypeFor } from "../../vault/paths.js";

/** Response headers clients must be able to read cross-origin. */
export const VAULT_EXPOSED_HEADERS = ["ETag", "Last-Modified", "X-Vault-Mtime"];

// Raw bytes of any Content-Type: .json/.canvas uploads must stay byte-exact, not be parsed.
const rawBody = express.raw({ type: () => true, limit: "25mb" });

const header = (req: Request, name: string) => req.get(name) || undefined;

/**
 * /v1/vault: the Obsidian vault's plain files (shared with Remotely Save through the bucket).
 * Mounted before the global JSON parser so PUT /file always receives raw bytes.
 */
export function vaultRouter({ vault }: Services): Router {
  const router = Router();

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
    });
    res
      .status(created ? 201 : 200)
      .set("ETag", `"${value.etag}"`)
      .json({ path: value.path, size: value.size, mtime: value.mtime, etag: value.etag });
  });

  router.delete("/file", async (req, res) => {
    await vault.delete(req.query.path, { ifMatch: header(req, "if-match") });
    res.status(204).end();
  });

  router.get("/search", async (req, res) => {
    res.json(await vault.search(req.query.q, { prefix: req.query.prefix, limit: req.query.limit }));
  });

  return router;
}
