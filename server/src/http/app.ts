import cors from "cors";
import express, { type Express } from "express";
import type { Classifier } from "../classifier/types.js";
import type { VaultConfig } from "../config.js";
import { mcpRouter } from "../mcp/route.js";
import { createServices } from "../services/index.js";
import type { ObsidianPluginService } from "../services/obsidian-plugin.js";
import type { Store } from "../store/types.js";
import type { VaultStore } from "../vault/types.js";
import { VERSION } from "../version.js";
import { requireApiKey } from "./auth.js";
import { errorHandler, notFoundHandler } from "./errors.js";
import { buildOpenApi } from "./openapi.js";
import { rateLimit } from "./rate-limit.js";
import { classifyRouter } from "./routes/classify.js";
import { obsidianPluginAdminRouter, obsidianPluginRouter } from "./routes/obsidian-plugin.js";
import { pairRouter, pairingRouter, publicBaseUrl } from "./routes/pairing.js";
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
  /** The bucket credentials behind `vault`, for GET /v1/vault/remotely-save (503 when null or omitted). */
  vaultConfig?: VaultConfig | null;
  /** PUBLIC_URL (no trailing slash) for pairing links and plugin file URLs; omitted = the request's scheme and host. */
  publicUrl?: string;
  /** Mirror of the Obsidian plugin's releases (index.ts passes the one it schedules); omitted = built over store and vault. */
  obsidianPlugin?: ObsidianPluginService;
  /** Clock in milliseconds for pairing code expiry and the /pair rate limit (injectable for tests). */
  now?: () => number;
}

/** /pair: attempts per client IP per window. */
export const PAIR_RATE_LIMIT = { limit: 10, windowMs: 10 * 60 * 1000 };

/** Builds the Express app without listening, so tests can drive it with supertest. */
export function createApp({
  store,
  classifier,
  apiKeys,
  vault = null,
  vaultConfig = null,
  publicUrl,
  obsidianPlugin,
  now = Date.now,
}: AppOptions): Express {
  const services = createServices({ store, classifier, vault, vaultConfig, obsidianPlugin, now });
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

  // No auth: this is how a new device obtains the key. After the JSON parser, rate-limited per IP.
  app.use("/pair", pairRouter(services, { limiter: rateLimit({ ...PAIR_RATE_LIMIT, now }) }));

  // No auth: plugin updates and first-install downloads (public code; files are checked against the database first).
  app.use("/obsidian-plugin", obsidianPluginRouter(services, { publicUrl }));

  const v1 = express.Router();
  v1.use(auth);
  v1.get("/openapi.json", (req, res) => {
    res.json(buildOpenApi(publicBaseUrl(req, publicUrl)));
  });
  v1.use("/pairing", pairingRouter(services, { publicUrl }));
  v1.use("/obsidian-plugin", obsidianPluginAdminRouter(services));
  v1.use("/scans", scansRouter(services));
  v1.use("/templates", templatesRouter(services));
  v1.use(classifyRouter(services));
  app.use("/v1", v1);

  app.use("/mcp", auth, mcpRouter(services));

  app.use(notFoundHandler);
  app.use(errorHandler);
  return app;
}
