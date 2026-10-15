import { Router } from "express";
import type { Services } from "../../services/index.js";

/** /v1/logistics: the logistics tracker (物流追蹤中心) over the vault's watch list (behind auth and the JSON parser). */
export function logisticsRouter({ logistics }: Services): Router {
  const router = Router();

  router.get("/", async (_req, res) => {
    res.set("Cache-Control", "no-store").json(await logistics.list());
  });

  router.post("/items", async (req, res) => {
    res.status(201).json({ item: await logistics.add(req.body) });
  });

  router.patch("/items/:number", async (req, res) => {
    res.json({ item: await logistics.update(req.params.number, req.body) });
  });

  router.delete("/items/:number", async (req, res) => {
    await logistics.remove(req.params.number);
    res.status(204).end();
  });

  router.post("/items/:number/refresh", async (req, res) => {
    res.json({ item: await logistics.refreshOne(req.params.number) });
  });

  router.post("/refresh", async (_req, res) => {
    res.json(await logistics.refreshAll());
  });

  router.post("/archive-delivered", async (_req, res) => {
    res.json(await logistics.archiveDelivered());
  });

  router.delete("/archived", async (_req, res) => {
    res.json(await logistics.clearArchived());
  });

  router.get("/linked", async (_req, res) => {
    res.set("Cache-Control", "no-store").json(await logistics.linked());
  });

  return router;
}
