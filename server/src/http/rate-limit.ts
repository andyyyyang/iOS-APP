import type { RequestHandler } from "express";
import { AppError } from "../errors.js";

export interface RateLimitOptions {
  /** Attempts allowed per window. */
  limit: number;
  windowMs: number;
  /** Milliseconds since the epoch (injectable for tests). */
  now?: () => number;
}

/**
 * In-memory sliding-window limit per client IP (`req.ip`; Railway's proxy is trusted).
 * Only allowed attempts count, so a client is let in again as soon as its oldest attempt leaves the window.
 * Fails with 429 rate_limited (+ Retry-After in seconds).
 */
export function rateLimit({ limit, windowMs, now = Date.now }: RateLimitOptions): RequestHandler {
  const attempts = new Map<string, number[]>();
  let lastSweep = now();

  return (req, res, next) => {
    const time = now();
    const since = time - windowMs;
    if (time - lastSweep >= windowMs) {
      // Forget clients that have been quiet for a whole window so the map cannot grow without bound.
      for (const [ip, times] of attempts) {
        if ((times.at(-1) ?? 0) <= since) attempts.delete(ip);
      }
      lastSweep = time;
    }

    const ip = req.ip ?? "unknown";
    const recent = (attempts.get(ip) ?? []).filter((at) => at > since);
    if (recent.length >= limit) {
      attempts.set(ip, recent);
      res.set("Retry-After", String(Math.max(1, Math.ceil((recent[0]! + windowMs - time) / 1000))));
      next(new AppError(429, "rate_limited", "Too many attempts; try again later"));
      return;
    }
    recent.push(time);
    attempts.set(ip, recent);
    next();
  };
}
