import { Router } from "express";
import type { Services } from "../../services/index.js";

export function templatesRouter({ templates }: Services): Router {
  const router = Router();

  router.get("/", async (_req, res) => {
    res.json({ items: await templates.list() });
  });

  router.get("/:id", async (req, res) => {
    res.json(await templates.get(req.params.id));
  });

  router.put("/:id", async (req, res) => {
    const { value, created } = await templates.put(req.params.id, req.body);
    res.status(created ? 201 : 200).json(value);
  });

  router.delete("/:id", async (req, res) => {
    await templates.delete(req.params.id);
    res.status(204).end();
  });

  return router;
}
