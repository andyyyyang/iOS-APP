import { Router } from "express";
import type { Services } from "../../services/index.js";

export function scansRouter({ scans }: Services): Router {
  const router = Router();

  router.get("/", async (req, res) => {
    res.json(await scans.list(req.query));
  });

  router.get("/:id", async (req, res) => {
    res.json(await scans.get(req.params.id));
  });

  router.put("/:id", async (req, res) => {
    const { value, created } = await scans.put(req.params.id, req.body);
    res.status(created ? 201 : 200).json(value);
  });

  router.patch("/:id", async (req, res) => {
    res.json(await scans.patch(req.params.id, req.body));
  });

  router.delete("/:id", async (req, res) => {
    await scans.delete(req.params.id);
    res.status(204).end();
  });

  return router;
}
