import { Router, type Response } from "express";
import type { Services } from "../../services/index.js";
import { releaseJson, type PluginFile } from "../../services/obsidian-plugin.js";
import { publicBaseUrl } from "./pairing.js";

/** A version's files never change; latest.json and /latest/ change with every release. */
const IMMUTABLE = "public, max-age=31536000, immutable";
const REVALIDATE = "no-cache";

function sendFile(res: Response, file: PluginFile, cacheControl: string): void {
  // setHeader keeps Content-Type exactly as given (res.set would append a charset to application/json)
  res.setHeader("Content-Type", file.contentType);
  res.set({
    ETag: `"${file.sha256}"`, // res.send answers 304 to a matching If-None-Match
    "Cache-Control": cacheControl,
    // A browser saves it as main.js / manifest.json (the manual first install)
    "Content-Disposition": `attachment; filename="${file.name}"`,
    "X-Content-Type-Options": "nosniff",
  });
  res.send(file.body);
}

/**
 * /obsidian-plugin (no auth): the LocalOCR Sync releases mirrored into the vault bucket, for the plugin's
 * online updates and the manual first install. The plugin code is public anyway (GitHub releases).
 */
export function obsidianPluginRouter({ obsidianPlugin }: Services, { publicUrl }: { publicUrl?: string }): Router {
  const router = Router();

  router.get("/latest.json", async (req, res) => {
    const release = await obsidianPlugin.latest();
    res.set("Cache-Control", REVALIDATE).json(releaseJson(release, publicBaseUrl(req, publicUrl)));
  });

  router.get("/latest/:file", async (req, res) => {
    sendFile(res, await obsidianPlugin.file(null, req.params.file), REVALIDATE);
  });

  router.get("/releases/:version/:file", async (req, res) => {
    sendFile(res, await obsidianPlugin.file(req.params.version, req.params.file), IMMUTABLE);
  });

  return router;
}

/** POST /v1/obsidian-plugin/refresh (behind API-key auth): mirror new GitHub releases now (CI calls it after publishing). */
export function obsidianPluginAdminRouter({ obsidianPlugin }: Services): Router {
  const router = Router();

  router.post("/refresh", async (_req, res) => {
    res.json(await obsidianPlugin.refresh());
  });

  return router;
}
