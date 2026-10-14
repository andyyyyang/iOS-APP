import { Router } from "express";
import type { Services } from "../../services/index.js";

/** /v1/assistant: request routing and cloud AI runs over the vault (behind auth and the JSON parser). */
export function assistantRouter({ assistant }: Services): Router {
  const router = Router();

  router.post("/route", async (req, res) => {
    res.json(await assistant.route(req.body));
  });

  // What the app's AI settings can pick: the models this key can call and the server's defaults.
  router.get("/models", async (_req, res) => {
    res.set("Cache-Control", "no-store").json(await assistant.modelSettings());
  });

  router.post("/runs", (req, res) => {
    res.status(202).json(assistant.start(req.body));
  });

  // Long poll (wait ≤ 25 s), like GET /v1/vault/changes.
  router.get("/runs/:id", async (req, res) => {
    const disconnected = new AbortController();
    res.on("close", () => disconnected.abort());
    const run = await assistant.get(req.params.id, req.query, disconnected.signal);
    if (disconnected.signal.aborted) return;
    res.set({ "Cache-Control": "no-store", "X-Accel-Buffering": "no" }).json(run);
  });

  router.post("/runs/:id/cancel", (req, res) => {
    res.json(assistant.cancel(req.params.id));
  });

  router.post("/runs/:id/undo", async (req, res) => {
    res.json(await assistant.undo(req.params.id, req.body));
  });

  return router;
}
