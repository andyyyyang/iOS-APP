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

export interface ApiKeyCheck {
  ok: boolean;
  /** The presented key that matched (with auth disabled: the first presented key, if any). Never log it. */
  key: string | undefined;
}

/**
 * Checks presented API keys against the configured ones: compared as SHA-256 digests with timingSafeEqual, checking
 * every configured key. An empty key list disables auth (only allowed by config in test / ALLOW_NO_AUTH mode).
 * Shared by the REST/MCP middleware and the WebSocket GET /v1/vault/stream (which gets its key in a message).
 */
export function apiKeyChecker(apiKeys: readonly string[]): (presented: readonly string[]) => ApiKeyCheck {
  const allowed = apiKeys.map(digest);
  return (presented) => {
    if (allowed.length === 0) return { ok: true, key: presented[0] };
    let matched: string | undefined;
    for (const key of presented) {
      const candidate = digest(key);
      let ok = false;
      for (const expected of allowed) ok = timingSafeEqual(candidate, expected) || ok;
      if (ok) matched ??= key;
    }
    return { ok: matched !== undefined, key: matched };
  };
}

/** API-key auth via `Authorization: Bearer <key>` or `?api_key=<key>` (see apiKeyChecker). */
export function requireApiKey(apiKeys: readonly string[]): RequestHandler {
  const check = apiKeyChecker(apiKeys);
  return (req, res, next) => {
    const { ok, key } = check(presentedKeys(req));
    if (ok) {
      res.locals.apiKey = key; // POST /v1/pairing hands this key to the paired device
      return next();
    }
    res
      .status(401)
      .set("WWW-Authenticate", 'Bearer realm="localocr"')
      .json({ error: { code: "unauthorized", message: "Missing or invalid API key" } });
  };
}
