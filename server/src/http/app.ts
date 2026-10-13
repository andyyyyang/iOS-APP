import cors from "cors";
import express, { type Express } from "express";
import type { Classifier } from "../classifier/types.js";
import { mcpRouter } from "../mcp/route.js";
import { createServices } from "../services/index.js";
import type { Store } from "../store/types.js";
import type { VaultStore } from "../vault/types.js";
import { VERSION } from "../version.js";
import { requireApiKey } from "./auth.js";
import { errorHandler, notFoundHandler } from "./errors.js";
import { buildOpenApi } from "./openapi.js";
import { classifyRouter } from "./routes/classify.js";
import { scansRouter } from "./routes/scans.js";
import { templatesRouter } from "./routes/templates.js";
import { VAULT_EXPOSED_HEADERS, vaultRouter } from "./routes/vault.js";

export interface AppOptions {
  store: Store;
  classifier: Classifier | null;
  /** Empty disables auth (config only allows that in test / ALLOW_NO_AUTH mode). */
  apiKeys: readonly string[];
  /** Obsidian vault storage; null or omitted when VAULT_S3_* is not configured (vault calls answer 503). */
  vault?: VaultStore | null;
}

/** Builds the Express app without listening, so tests can drive it with supertest. */
export function createApp({ store, classifier, apiKeys, vault = null }: AppOptions): Express {
  const services = createServices({ store, classifier, vault });
  const auth = requireApiKey(apiKeys);
  const app = express();

  app.disable("x-powered-by");
  app.set("trust proxy", true); // Railway terminates TLS at its proxy
  app.use(cors({ origin: "*", exposedHeaders: ["WWW-Authenticate", ...VAULT_EXPOSED_HEADERS] }));
  // Before the JSON parser: vault uploads are raw bytes (a .json note must not be parsed or size-limited to 5mb)
  app.use("/v1/vault", auth, vaultRouter(services));
  app.use(express.json({ limit: "5mb" }));

  app.get("/health", (_req, res) => {
    res.json({ status: "ok", version: VERSION, database: store.kind, jev: services.classify.available });
  });

  const v1 = express.Router();
  v1.use(auth);
  v1.get("/openapi.json", (req, res) => {
    res.json(buildOpenApi(`${req.protocol}://${req.get("host")}`));
  });
  v1.use("/scans", scansRouter(services));
  v1.use("/templates", templatesRouter(services));
  v1.use(classifyRouter(services));
  app.use("/v1", v1);

  app.use("/mcp", auth, mcpRouter(services));

  app.use(notFoundHandler);
  app.use(errorHandler);
  return app;
}
