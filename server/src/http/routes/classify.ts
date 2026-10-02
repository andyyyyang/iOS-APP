import { Router } from "express";
import type { Services } from "../../services/index.js";

/** POST /v1/classify and POST /v1/validate. */
export function classifyRouter({ classify, validate }: Services): Router {
  const router = Router();

  router.post("/classify", async (req, res) => {
    res.json(await classify.classify(req.body));
  });

  router.post("/validate", async (req, res) => {
    res.json(await validate.validate(req.body));
  });

  return router;
}
