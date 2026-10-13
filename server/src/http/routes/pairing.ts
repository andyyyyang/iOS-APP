import { Router, type Request, type RequestHandler } from "express";
import type { Services } from "../../services/index.js";
import { authenticatedKey } from "../auth.js";

/** Pairing responses carry an API key (or the code that redeems it): never cache them. */
const noStore: RequestHandler = (_req, res, next) => {
  res.set("Cache-Control", "no-store");
  next();
};

/** PUBLIC_URL when set, otherwise this request's scheme and host (Railway's proxy is trusted). */
export function publicBaseUrl(req: Request, publicUrl: string | undefined): string {
  return publicUrl ?? `${req.protocol}://${req.get("host")}`;
}

/** The link the LocalOCR app opens (or reads from the QR code) to pair with this server. */
export const pairUrl = (baseUrl: string, code: string) =>
  `localocr://pair?server=${encodeURIComponent(baseUrl)}&code=${code}`;

/** POST /v1/pairing (behind API-key auth): a single-use code that hands this request's key to a new device. */
export function pairingRouter({ pairing }: Services, { publicUrl }: { publicUrl?: string }): Router {
  const router = Router();

  router.post("/", noStore, (req, res) => {
    const created = pairing.create(authenticatedKey(res) ?? "", req.body);
    res.status(201).json({ ...created, pairUrl: pairUrl(publicBaseUrl(req, publicUrl), created.code) });
  });

  return router;
}

/** POST /pair (no auth; rate-limited by the caller): redeems a code for the API key. */
export function pairRouter({ pairing }: Services, { limiter }: { limiter: RequestHandler }): Router {
  const router = Router();

  router.post("/", noStore, limiter, (req, res) => {
    res.json(pairing.claim(req.body));
  });

  return router;
}
