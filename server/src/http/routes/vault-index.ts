import { Router } from "express";
import type { Services } from "../../services/index.js";
import { normalizeEtag } from "../../vault/paths.js";

const acceptsGzip = (header: string | undefined) =>
  (header ?? "").split(",").some((part) => {
    const [coding, ...params] = part.trim().toLowerCase().split(";");
    return coding?.trim() === "gzip" && !params.some((param) => /^\s*q\s*=\s*0(\.0*)?\s*$/.test(param));
  });

/** GET /v1/vault/index (mounted at that path, behind auth): every note's parsed fields plus the other files. */
export function vaultIndexRouter({ vaultIndex }: Services): Router {
  const router = Router();
  router.get("/", async (req, res) => {
    const snapshot = await vaultIndex.snapshot();
    const etag = `"${snapshot.etag}"`;
    res.set({ ETag: etag, "Cache-Control": "no-cache", Vary: "Accept-Encoding" });
    const ifNoneMatch = req.get("if-none-match");
    if (ifNoneMatch && ifNoneMatch.split(",").some((tag) => tag.trim() === "*" || normalizeEtag(tag) === snapshot.etag)) {
      res.status(304).end();
      return;
    }
    res.setHeader("Content-Type", "application/json; charset=utf-8");
    if (acceptsGzip(req.get("accept-encoding"))) {
      res.setHeader("Content-Encoding", "gzip");
      res.send(await snapshot.gzipped());
      return;
    }
    res.send(Buffer.from(snapshot.json, "utf8"));
  });
  return router;
}
