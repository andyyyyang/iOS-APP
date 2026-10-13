import { createHash, timingSafeEqual } from "node:crypto";
import type { Request, RequestHandler, Response } from "express";

const digest = (value: string) => createHash("sha256").update(value, "utf8").digest();

function presentedKeys(req: Request): string[] {
  const keys: string[] = [];
  const match = /^Bearer\s+(.+)$/i.exec(req.get("authorization")?.trim() ?? "");
  if (match?.[1]) keys.push(match[1].trim());
  const queryKey = (req.query as Record<string, unknown>).api_key;
  if (typeof queryKey === "string" && queryKey) keys.push(queryKey);
  return keys;
}

/**
 * The API key that authenticated this request (set by requireApiKey). Never log it.
 * With auth disabled it is whatever key the client sent, or undefined.
 */
export function authenticatedKey(res: Response): string | undefined {
  const key: unknown = res.locals.apiKey;
  return typeof key === "string" ? key : undefined;
}

/**
 * API-key auth via `Authorization: Bearer <key>` or `?api_key=<key>`.
 * Keys are compared as SHA-256 digests with timingSafeEqual, checking every configured key.
 * An empty key list disables auth (only allowed by config in test / ALLOW_NO_AUTH mode).
 */
export function requireApiKey(apiKeys: readonly string[]): RequestHandler {
  const allowed = apiKeys.map(digest);
  return (req, res, next) => {
    const keys = presentedKeys(req);
    if (allowed.length === 0) {
      res.locals.apiKey = keys[0];
      return next();
    }
    let matched: string | undefined;
    for (const key of keys) {
      const candidate = digest(key);
      let ok = false;
      for (const expected of allowed) ok = timingSafeEqual(candidate, expected) || ok;
      if (ok) matched ??= key;
    }
    if (matched !== undefined) {
      res.locals.apiKey = matched; // POST /v1/pairing hands this key to the paired device
      return next();
    }
    res
      .status(401)
      .set("WWW-Authenticate", 'Bearer realm="localocr"')
      .json({ error: { code: "unauthorized", message: "Missing or invalid API key" } });
  };
}
